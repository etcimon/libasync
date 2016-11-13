
immutable HELP = "Minimalistic netcat-alike

Usage:
  ncat -h | --help
  ncat -l [-46uk] <address> <port>
  ncat -l [-46uk] <port>
  ncat -lU [-uk] <address>
  ncat [-46u] <address> <port>
  ncat [-46u] <port>
  ncat -U [-u] <address>

Options:
  -h --help    Show this screen.
  -l           Start in listen mode, allowing inbound connects
  -k           Keep listening for another connection after the
               current one has been closed.
  -4           Operate in the IPv4 address family.
  -6           Operate in the IPv6 address family [default].
  -U           Operate in the UNIX domain socket address family (Posix platforms only).
  -u           Use datagram socket (e.g. UDP)
";

int main(string[] args)
{
	auto arguments = docopt.docopt(HELP, args[1..$], true);

	auto af = getAddressFamily(arguments);

	NetworkAddress address = void;
	try address = getAddress(arguments, af); catch (Exception e) {
		stderr.writeln("ncat: ", e.msg);
		return 1;
	}

	auto type = getType(arguments);
	auto mode = getMode(arguments);
	auto keepListening = keepListening(arguments);

	g_running = true;
	g_eventLoop = getThreadEventLoop();
	if (mode == Mode.Listen) {
		if (!listen(address, af, type, keepListening)) return 1;
	} else {
		if (!connect(address, af, type)) return 1;
	}
	while (g_running) g_eventLoop.loop(-1.seconds);
	return g_status;
}

bool connect(ref NetworkAddress remote, int af, SocketType type)
{
	g_client = ThreadMem.alloc!AsyncSocket(g_eventLoop, af, type);
	if (g_client.connectionOriented) transceive(g_client, { g_running = false; });

	if(!g_client.run()) {
		stderr.writeln("ncat: ", g_client.error);
		ThreadMem.free(g_client);
		g_client = null;
		return false;
	}

	if (!g_client.connect(remote)) {
		stderr.writeln("ncat: ", g_client.error);
		ThreadMem.free(g_client);
		g_client = null;
		return false;
	}
	if (!g_client.connectionOriented) {
		transceive(g_client);
		version (Posix) if (af == AF_UNIX) {
			import std.path: buildPath;
			import std.file: tempDir;
			import std.conv : to;
			import std.random: randomCover;
			import std.range: take;
			import std.ascii: hexDigits;
			import std.array: array;

			auto localName = buildPath(tempDir, "ncat." ~ hexDigits.array.randomCover.take(8).array.to!string);

			NetworkAddress local;
			local.sockAddr.sa_family = AF_UNIX;
			(cast(sockaddr_un*) local.sockAddr).sun_path[0 .. localName.length] = cast(byte[]) localName[];
			if (!g_client.bind(local)) {
				stderr.writeln("ncat: ", g_client.error);
				ThreadMem.free(g_client);
				g_client = null;
				return false;
			}
		}
	}

	return true;
}

bool listen(ref NetworkAddress local, int af, SocketType type, bool keepListening = false)
{
	g_listener = ThreadMem.alloc!AsyncSocket(g_eventLoop, af, type);
	setupError(g_listener);

	if(!g_listener.run()) {
		stderr.writeln("ncat: ", g_listener.error);
		ThreadMem.free(g_listener);
		g_listener = null;
		return false;
	}

	try switch (af) {
		case AF_INET, AF_INET6:
			int yes = 1;
			g_listener.setOption(SOL_SOCKET, SO_REUSEADDR, (cast(ubyte*) &yes)[0..yes.sizeof]);
			version (Posix) g_listener.setOption(SOL_SOCKET, SO_REUSEPORT, (cast(ubyte*) &yes)[0..yes.sizeof]);
			break;
		version (Posix) {
		case AF_UNIX:
			auto path = to!string(cast(const(char)*) local.sockAddrUnix.sun_path.ptr).ifThrown("");
			if (path.exists && !path.isDir) path.remove.collectException;
			break;
		}
		default: assert(false);
	} catch (Exception e) {
		stderr.writeln("ncat: ", e.msg);
		return false;
	}

	if (!g_listener.bind(local)) {
		stderr.writeln("ncat: ", g_listener.error);
		ThreadMem.free(g_listener);
		g_listener = null;
		return false;
	}

	if (!g_listener.connectionOriented) {
		NetworkAddress from, to;
		mixin StdInTransmitter transmitter;

		transmitter.start(g_listener, to);
		g_listener.receive({
			auto buffer = new ubyte[4096];
			g_listener.receiveContinuously = true;
			g_listener.receiveFrom(buffer, from, (data) {
				if (to == NetworkAddress.init) {
					to = from;
					transmitter.reader.loop();
				}
				if (from == to) {
					stdout.rawWrite(data).collectException();
					stdout.flush().collectException();
				}
			});
		});
	} else if (!g_listener.listen()) {
		stderr.writeln("ncat: ", g_listener.error);
		ThreadMem.free(g_listener);
		g_listener = null;
		return false;
	} else {
		g_onAccept = (handle, family, type, protocol) {
			if (!keepListening) {
				g_listener.kill();
				assumeWontThrow(ThreadMem.free(g_listener));
				g_listener = null;
			}
			g_client = assumeWontThrow(ThreadMem.alloc!AsyncSocket(g_eventLoop, family, type, protocol, handle));
			transceive(g_client, {
				assumeWontThrow(ThreadMem.free(g_client));
				g_client = null;
				if (g_listener) g_listener.accept(g_onAccept);
				else g_running = false;
			});
			return g_client;
		};

		g_listener.accept(g_onAccept);
	}

	return true;
}

AsyncAcceptRequest.OnComplete g_onAccept = void;

void setupError(ref AsyncSocket socket, bool exit = true) nothrow
{
	socket.onError = {
		stderr.writeln("ncat: ", socket.error).collectException();
		if (exit) {
			g_running = false;
			g_status = 1;
		}
	};
}

mixin template StdInTransmitter()
{
	auto readBuffer = new shared ubyte[4096];
	shared size_t readCount;

	auto onRead = new shared AsyncSignal(g_eventLoop);
	auto reader = new StdInReader(readBuffer, readCount, onRead);

	void start(ref AsyncSocket socket) nothrow {
		onRead.run({
			if (readCount == 0) {
				if (socket.connectionOriented) {
					socket.kill();
					assumeWontThrow(ThreadMem.free(socket));
					socket = null;
					if (g_listener) g_listener.accept(g_onAccept);
					else g_running = false;
				}
				reader.stop();
			} else {
				socket.send(cast(ubyte[]) readBuffer[0..readCount], { reader.loop(); });
			}
		});
		reader.start();
		reader.loop();
	}

	void start(ref AsyncSocket socket, ref NetworkAddress to) nothrow {
		onRead.run({
			if (readCount == 0) {
				to = NetworkAddress.init;
			} else {
				socket.sendTo(cast(ubyte[]) readBuffer[0..readCount], to, { reader.loop(); });
			}
		});
		reader.start();
	}
}

void transceive(ref AsyncSocket socket, AsyncSocket.OnClose onClose = null) nothrow
{
	setupError(socket);

	if (socket.connectionOriented) {
		socket.onConnect = {
			socket.receive({
				auto buffer = new ubyte[4096];
				socket.receiveContinuously = true;
				socket.receive(buffer, (data) {
					stdout.rawWrite(data).collectException();
					stdout.flush().collectException();
				});
			});

			mixin StdInTransmitter transmitter;
			transmitter.start(socket);
		};
		if (onClose) socket.onClose = onClose;
	} else {
		socket.receive({
			auto buffer = new ubyte[4096];
			socket.receiveContinuously = true;
			socket.receive(buffer, (data) {
				stdout.rawWrite(data).collectException();
				stdout.flush().collectException();
			});
		});

		mixin StdInTransmitter transmitter;
		transmitter.start(socket);
	}
}

class StdInReader : Thread
{
private:
	import core.sync.semaphore : Semaphore;

	shared ubyte[] m_buffer;
	shared size_t* m_readCount;
	shared AsyncSignal m_onRead;
	shared bool m_running;

	Semaphore m_sem;

public:
	this(shared ubyte[] buffer, shared ref size_t readCount, shared AsyncSignal onRead) nothrow
	{
		m_buffer = buffer;
		m_onRead = onRead;
		m_readCount = &readCount;
		m_sem = assumeWontThrow(new Semaphore(0));
		m_running = true;
		assumeWontThrow(isDaemon = true);
		assumeWontThrow(super(&run));
	}

	version (Posix) void run()
	{
		import core.sys.posix.unistd : STDIN_FILENO, read;

		m_sem.wait();
		while (m_running && g_running) {
			*m_readCount = read(STDIN_FILENO, cast(void*) m_buffer.ptr, m_buffer.length);
			m_onRead.trigger();
			m_sem.wait();
		}
	}

	version (Windows) void run()
	{
		import libasync.internals.win32 : HANDLE, DWORD, GetStdHandle, ReadFile;
		enum STD_INPUT_HANDLE = cast(DWORD) -10;
		enum INVALID_HANDLE_VALUE = cast(HANDLE) -1;

		auto stdin = GetStdHandle(STD_INPUT_HANDLE);
		assert(stdin != INVALID_HANDLE_VALUE, "ncat: Failed to get standard input handle");

		m_sem.wait();
		while (m_running && g_running) {
			DWORD bytesRead = void;
			auto err = ReadFile(stdin, cast(void*) m_buffer.ptr, cast(DWORD) m_buffer.length, &bytesRead, null);
			*m_readCount = bytesRead;
			m_onRead.trigger();
			m_sem.wait();
		}
	}

	void stop() nothrow
	{ m_running = false; loop(); }

	void loop() nothrow
	{ assumeWontThrow(m_sem.notify()); }
}

shared bool g_running;
EventLoop g_eventLoop;
int g_status;

AsyncSocket g_listener, g_client;

enum Mode { Connect, Listen }

auto getAddressFamily(A)(A arguments)
{
	if (arguments["-6"].isTrue) return AddressFamily.INET6;
	else if (arguments["-4"].isTrue) return AddressFamily.INET;
	else if (arguments["-U"].isTrue) return AddressFamily.UNIX;
	return AddressFamily.INET6;
}

auto getAddress(A)(A arguments, int af)
{
	auto address = arguments["<address>"];
	ushort port = void;

	if (!arguments["<port>"].isNull) try {
		port = arguments["<port>"].toString.to!ushort;
	} catch (Exception) {
		throw new Exception("port must be integer and 0 <= port <= %s, not '%s'".format(ushort.max, arguments["<port>"]));
	}

	if (address.isNull) switch (af) {
		case AF_INET: with (new InternetAddress("0.0.0.0", port)) return NetworkAddress(name, nameLen);
		case AF_INET6: with (new Internet6Address("::", port)) return NetworkAddress(name, nameLen);
		default: assert(false);
	}

	switch (af) {
		case AF_INET: with (new InternetAddress(address.toString, port)) return NetworkAddress(name, nameLen);
		case AF_INET6: with (new Internet6Address(address.toString, port)) return NetworkAddress(name, nameLen);
		version (Posix) case AF_UNIX: with(new UnixAddress(address.toString)) return NetworkAddress(name, nameLen);
		default: assert(false);
	}
}

auto getType(A)(A arguments)
{ return arguments["-u"].isTrue? SocketType.DGRAM : SocketType.STREAM; }

auto getMode(A)(A arguments)
{ return arguments["-l"].isTrue? Mode.Listen : Mode.Connect; }

auto keepListening(A)(A arguments)
{ return arguments["-k"].isTrue; }

import core.time;
import core.thread;
import core.atomic;

import std.stdio;
import std.socket;
import std.conv;
import std.format;
import std.file;
import std.exception;

import memutils.utils;

import libasync;
import docopt;