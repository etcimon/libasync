
immutable HELP = "Receive/Send data continuously

Usage:
  transceiver -h | --help
  transceiver -l [-46u] <address> <port>
  transceiver -l [-46u] <port>
  transceiver [-46u] <address> <port>
  transceiver [-46u] <port>

Options:
  -h --help    Show this screen.
  -l           Start in listen mode, allowing inbound connects
  -4           Operate in the IPv4 address family.
  -6           Operate in the IPv6 address family [default].
  -u           Use datagram socket (e.g. UDP)
";

int main(string[] args)
{
	auto arguments = docopt.docopt(HELP, args[1..$], true);

	auto af = getAddressFamily(arguments);

	NetworkAddress address = void;
	try address = getAddress(arguments, af); catch (Exception e) {
		stderr.writeln("transceiver: ", e.msg);
		return 1;
	}

	auto type = getType(arguments);

	auto mode = getMode(arguments);

	g_running = true;
	g_eventLoop = getThreadEventLoop();
	g_receiveBuffer = new ubyte[4096];
	if (mode == Mode.Listen) {
		if (!listen(address, af, type)) return 1;
	} else {
		if (!connect(address, af, type)) return 1;
	}
	while (g_running) g_eventLoop.loop(-1.seconds);
	return g_status;
}

bool connect(ref NetworkAddress remote, int af, SocketType type)
{
	auto socket = new AsyncSocket(g_eventLoop, af, type);
	transceive(socket);

	if(!socket.run()) {
		stderr.writeln("transceiver: ", socket.error);
		return false;
	}

	if (!socket.connect(remote)) {
		stderr.writeln("transceiver: ", socket.error);
		return false;
	}

	return true;
}

bool listen(ref NetworkAddress local, int af, SocketType type)
{
	auto running = true;
	auto eventLoop = getThreadEventLoop();
	auto listener = new AsyncSocket(eventLoop, af, type);

	listener.onError = {
		stderr.writeln("transceiver: ", listener.error).collectException();
		g_status = 1;
		running = false;
	};

	if (listener.connectionOriented) listener.onAccept = (client) { transceive(client); };

	if(!listener.run()) {
		stderr.writeln("transceiver: ", listener.error);
		return false;
	}

	int yes = 1;
	// None of the errors described for setsockopt (EBADF,EFAULT,EINVAL,ENOPROTOOPT,ENOTSOCK)
	// can happen here unless there is a bug somewhere else.
	assert(setsockopt(listener.handle, SocketOptionLevel.SOCKET, SO_REUSEADDR, &yes, yes.sizeof) == 0);
	version (Posix) assert(setsockopt(listener.handle, SocketOptionLevel.SOCKET, SO_REUSEPORT, &yes, yes.sizeof) == 0);

	if (!listener.bind(local)) {
		stderr.writeln("transceiver: ", listener.error);
		return false;
	}

	if (!listener.connectionOriented) {
		// TODO: Receive
	} else if (!listener.listen(128)) {
		stderr.writeln("transceiver: ", listener.error);
		return false;
	}

	return true;
}

void transceive(AsyncSocket socket) nothrow
{
	import std.random : randomCover, randomSample, uniform;
	import std.ascii : letters;

	void delegate() delegate(size_t, size_t, void delegate()) nothrow createSender = (i, n, onComplete) {
		static dataGenerator = generate!(() => cast(ubyte) letters[uniform(0, letters.length)]);

		auto index = assumeWontThrow(i.to!string);
		auto dataOffset = 5 + index.length + 2;
		auto data = new ubyte[dataOffset + n + 1];

		data[0..5] = cast(ubyte[]) "send_";
		data[5..5+index.length] = cast(ubyte[]) index;
		data[dataOffset-2..dataOffset] = cast(ubyte[]) ": ";
		data[$-1] = '\n';

		return delegate void() {
			data[dataOffset..$-1] = dataGenerator.take(n).array;
			socket.send(data, onComplete);
		};
	};

	auto senders = new void delegate()[3];
	auto onSent = { senders.randomSample(1).front()(); };

	socket.onConnect = {
		foreach (i, ref sender; senders) {
			sender = createSender(i, 2 << (3+i), { onSent(); });
		}

		if (senders.length > 0) senders[0]();
		socket.receiveContinuously = true;
		socket.receive(g_receiveBuffer, (data) {
			stdout.rawWrite(data);
			stdout.flush();
		});
	};
	socket.onClose = { g_running = false; };
	socket.onError = {
		stderr.writeln("transceiver: ", socket.error).collectException();
		g_running = false;
		g_status = 1;
	};
}

bool g_running;
EventLoop g_eventLoop;
int g_status;
ubyte[] g_receiveBuffer;

enum Mode { Connect, Listen }

auto getAddressFamily(A)(A arguments)
{ return arguments["-4"].isTrue? AF_INET : AF_INET6; }

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
		default: assert(false);
	}
}

auto getType(A)(A arguments)
{ return arguments["-u"].isTrue? SocketType.DGRAM : SocketType.STREAM; }

auto getMode(A)(A arguments)
{ return arguments["-l"].isTrue? Mode.Listen : Mode.Connect; }

import core.time;

import std.stdio;
import std.socket;
import std.conv;
import std.format;
import std.file;
import std.exception;
import std.range;

import libasync;
import libasync.internals.socket_compat;

import docopt;