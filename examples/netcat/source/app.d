
immutable HELP = "Minimalistic netcat-alike

Usage:
  ncat -h | --help
  ncat -l [-46u] <address> <port>
  ncat -l [-46u] <port>
  ncat -lU [-u] <address>
  ncat [-46u] <address> <port>
  ncat [-46u] <port>
  ncat -U [-u] <address>

Options:
  -h --help    Show this screen.
  -l           Start in listen mode, allowing inbound connects
  -4           Operate in the IPv4 address family.
  -6           Operate in the IPv6 address family [default].
  -U           Operate in the UNIX domain socket address family.
  -u           Use datagram socket (e.g. UDP)
";

enum Mode
{
	Connect,
	Listen
}

auto getAddressFamily(A)(A arguments)
{
	if (arguments["-6"].isTrue) return AddressFamily.INET6;
	else if (arguments["-4"].isTrue) return AddressFamily.INET;
	else if (arguments["-U"].isTrue) return AddressFamily.UNIX;
	return AddressFamily.INET6;
}

Address getAddress(A)(A arguments, AddressFamily af)
{
	auto address = arguments["<address>"];
	ushort port = void;

	if (!arguments["<port>"].isNull) try {
		port = arguments["<port>"].toString.to!ushort;
	} catch (Exception) {
		throw new Exception("port must be integer and 0 <= port <= %s, not '%s'".format(ushort.max, arguments["<port>"]));
	}

	if (address.isNull) switch (af) with (AddressFamily) {
		case INET: return new InternetAddress("0.0.0.0", port);
		case INET6: return new Internet6Address("::", port);
		default: assert(false);
	}

	switch (af) with (AddressFamily) {
		case INET: return new InternetAddress(address.toString, port);
		case INET6: return new Internet6Address(address.toString, port);
		case UNIX: return new UnixAddress(address.toString);
		default: assert(false);
	}
}

auto getType(A)(A arguments)
{
	if (arguments["-u"].isTrue) return SocketType.DGRAM;
	return SocketType.STREAM;
}

auto getMode(A)(A arguments)
{
	if (arguments["-l"].isTrue) return Mode.Listen;
	return Mode.Connect;
}

int main(string[] args)
{
	auto arguments = docopt.docopt(HELP, args[1..$], true);

	auto af = getAddressFamily(arguments);
	
	Address address = void;
	try address = getAddress(arguments, af);
	catch (Exception e) {
		stderr.writeln("ncat: ", e.msg);
		return 1;
	}

	auto type = getType(arguments);

	final switch (getMode(arguments)) with (Mode) {
		case Listen:
			return listenMode(address, af, type);
		case Connect:
			return connectMode(address, af, type);
	}
}

int connectMode(Address remote, AddressFamily af, SocketType type)
{
	import libasync.internals.socket_compat : setsockopt, SO_REUSEPORT;
	auto running = true;

	auto eventLoop = getThreadEventLoop();

	auto client = new AsyncSocket(eventLoop, af, type);

	auto socketRecvBuf = new ubyte[4096];
	auto stdinReadBuf = new shared ubyte[4096];
	shared ubyte[] input;

	shared AsyncSignal handleSTDIN = new shared AsyncSignal(eventLoop);
	void delegate() readAndSend = void;

	void delegate(ubyte[] data) send = void;
	if (client.connectionOriented) {
		send = (data) => client.send(data, { if (client.alive) doOffThread(readAndSend); });
	} else {
		send = (data) => client.sendTo(cast(ubyte[]) input, NetworkAddress(remote), { if (client.alive) doOffThread(readAndSend); });
	}


	handleSTDIN.run({
		if (input.length > 0) {
			send(cast(ubyte[]) input);
		} else {
			running = false;
		}
	});

	readAndSend = {
		input = cast(shared ubyte[]) stdin.rawRead(cast(ubyte[]) stdinReadBuf);
		handleSTDIN.trigger();
	};

	if (client.connectionOriented) {
		client.onConnect = {
			client.startReceiving(socketRecvBuf, (data) {
				stdout.rawWrite(data);
				stdout.flush();
			});

			doOffThread(readAndSend);
		};

		client.onClose = { running = false; };
	}

	client.onError = {
		stderr.writeln("ncat: ", client.error);
		running = false;
	};

	if(!client.run()) {
		stderr.writeln("ncat: ", client.error);
		return 1;
	}

	if (client.connectionOriented && !client.connect(remote.name, remote.nameLen)) {
		stderr.writeln("ncat: ", client.status.text);
		return 1;
	} else if (af == AddressFamily.UNIX) {
		import std.path: buildPath;
		import std.file: tempDir;
		import std.conv : to;
		import std.random: randomCover;
		import std.range: take;
		import std.ascii: hexDigits;
		import std.array: array;

		auto localName = buildPath(tempDir, "ncat." ~ hexDigits.array.randomCover.take(8).array.to!string);

		NetworkAddress local;
		local.sockAddr.sa_family = AddressFamily.UNIX;
		(cast(sockaddr_un*) local.sockAddr).sun_path[0 .. localName.length] = cast(byte[]) localName[];
		if (!client.bind(local)) {
			stderr.writeln("ncat: ", client.status.text);
			return 1;
		}
	}

	if (!client.connectionOriented) {
		client.startReceiving(socketRecvBuf, (data) {
			stdout.rawWrite(data);
			stdout.flush();
		});

		doOffThread(readAndSend);
	}

	while (running) eventLoop.loop(-1.seconds);
	return 0;
}

int listenMode(Address local, AddressFamily af, SocketType type)
{
	import libasync.internals.socket_compat : setsockopt, SO_REUSEADDR, SO_REUSEPORT;
	auto running = true;

	auto eventLoop = getThreadEventLoop();

	auto listener = new AsyncSocket(eventLoop, af, type);

	auto socketRecvBuf = new ubyte[4096];
	auto stdinReadBuf = new shared ubyte[4096];
	shared ubyte[] input;

	if (listener.connectionOriented) listener.onAccept = (client) {
		listener.kill();

		client.onConnect = {
			client.startReceiving(socketRecvBuf, (data) {
				stdout.rawWrite(data);
				stdout.flush();
			});

			shared AsyncSignal handleSTDIN = new shared AsyncSignal(eventLoop);
			void delegate() readAndSend = void;

			handleSTDIN.run({
				if (input.length > 0) {
					client.send(cast(ubyte[]) input, { if (client.alive) doOffThread(readAndSend); });
				} else {
					running = false;
				}
			});

			readAndSend = {
				input = cast(shared ubyte[]) stdin.rawRead(cast(ubyte[]) stdinReadBuf);
				handleSTDIN.trigger();
			};

			doOffThread(readAndSend);
		};

		client.onClose = { running = false; };
		client.onError = { stderr.writeln("ncat: ", client.error); };
	};

	listener.onError = { stderr.writeln("ncat: ", listener.error); };

	if(!listener.run()) {
		stderr.writeln("ncat: ", listener.error);
		return 1;
	}

	if (af != AddressFamily.UNIX) {
		int yes = 1;
		// None of the errors described for setsockopt (EBADF,EFAULT,EINVAL,ENOPROTOOPT,ENOTSOCK)
		// can happen here unless there is a bug somewhere else.
		assert(setsockopt(listener.handle, SocketOptionLevel.SOCKET, SO_REUSEADDR, &yes, yes.sizeof) == 0);
		assert(setsockopt(listener.handle, SocketOptionLevel.SOCKET, SO_REUSEPORT, &yes, yes.sizeof) == 0);
	} else {
		auto path = (cast(UnixAddress) local).path;
		if (path.exists && !path.isDir) try path.remove;
		catch (Exception) {}
	}

	if (!listener.bind(NetworkAddress(local))) {
		stderr.writeln("ncat: ", listener.status.text);
		return 1;
	}

	if (!listener.connectionOriented) {
		NetworkAddress remoteAddr;
		listener.startReceivingFrom(socketRecvBuf, (data) {
			stdout.rawWrite(data);
			stdout.flush();
		}, remoteAddr);
	}
	else if (!listener.listen(128)) {
		stderr.writeln("ncat: ", listener.status.text);
		return 1;	
	}

	while (running) eventLoop.loop(-1.seconds);
	return 0;
}

void doOffThread(void delegate() dg)
{
	auto worker = new Thread({ dg(); });
	worker.isDaemon = true;
	worker.start();
}

import core.time;
import core.thread;
import core.atomic;

import std.stdio;
import std.socket;
import std.conv;
import std.format;
import std.file;

import libasync;
import docopt;