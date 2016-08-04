
immutable HELP = "Receive/Send data continuously

Usage:
  transceiver -h | --help
  transceiver -l [-46] <address> <port>
  transceiver -l [-46] <port>
  transceiver [-46] <address> <port>
  transceiver [-46] <port>

Options:
  -h --help    Show this screen.
  -l           Start in listen mode, allowing inbound connects
  -4           Operate in the IPv4 address family.
  -6           Operate in the IPv6 address family [default].
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

	auto mode = getMode(arguments);

	g_running = true;
	g_eventLoop = getThreadEventLoop();
	g_receiveBuffer = new ubyte[4096];
	if (mode == Mode.Listen) {
		if (!listen(address, af, SOCK_STREAM)) return 1;
	} else {
		if (!connect(address, af, SOCK_STREAM)) return 1;
	}
	while (g_running) g_eventLoop.loop(-1.seconds);
	return g_status;
}

bool connect(ref NetworkAddress remote, int af, int type)
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

bool listen(ref NetworkAddress local, int af, int type)
{
	auto listener = new AsyncSocket(g_eventLoop, af, type);

	listener.onError = {
		stderr.writeln("transceiver: ", listener.error).collectException();
		g_status = 1;
		g_running = false;
	};

	if(!listener.run()) {
		stderr.writeln("transceiver: ", listener.error);
		return false;
	}

	try {
		int yes = 1;
		listener.setOption(SOL_SOCKET, SO_REUSEADDR, (cast(ubyte*) &yes)[0..yes.sizeof]);
		version (Posix) listener.setOption(SOL_SOCKET, SO_REUSEPORT, (cast(ubyte*) &yes)[0..yes.sizeof]);
	} catch (Exception e) {
		stderr.writeln("transceiver: ", e.msg);
		return false;
	}

	if (!listener.bind(local)) {
		stderr.writeln("transceiver: ", listener.error);
		return false;
	}

	if (!listener.listen()) {
		stderr.writeln("transceiver: ", listener.error);
		return false;
	}

	AsyncAcceptRequest.OnComplete onAccept = void;
	onAccept = (handle, family, type, protocol) {
		scope (exit) if (listener.alive) listener.accept(onAccept);
		auto client = new AsyncSocket(g_eventLoop, family, type, protocol, handle);
		transceive(client, true, false);
		return client;
	};

	listener.accept(onAccept);

	return true;
}

void transceive(AsyncSocket socket, bool send = true, bool exitOnClose = true) nothrow
{
	import std.random : randomCover, randomSample, uniform;
	import std.ascii : letters;

	void delegate() nothrow delegate(size_t, size_t, void delegate() nothrow) nothrow createSender = (i, n, onComplete) {
		static dataGenerator = generate!(() => cast(ubyte) letters[uniform(0, letters.length)]);

		auto index = assumeWontThrow(i.to!string);
		auto dataOffset = 5 + index.length + 2;
		auto data = new ubyte[dataOffset + n + 1];

		data[0..5] = cast(ubyte[]) "send_";
		data[5..5+index.length] = cast(ubyte[]) index;
		data[dataOffset-2..dataOffset] = cast(ubyte[]) ": ";
		data[$-1] = '\n';

		return delegate void() nothrow {
			if (socket.alive) {
				assumeWontThrow(data[dataOffset..$-1] = dataGenerator.take(n).array);
				socket.send(data, onComplete);
			}
		};
	};

	auto senders = new void delegate() nothrow[1];
	auto onSent = { assumeWontThrow(senders.randomSample(1).front())(); };

	socket.onConnect = delegate void() nothrow {
		foreach (i, ref sender; senders) {
			sender = createSender(i, 2 << (3+i), { onSent(); });
		}

		if (send && senders.length > 0) assumeWontThrow(senders.front())();
		socket.receiveContinuously = true;
		socket.receive(g_receiveBuffer, (data) {
			try {
				stdout.rawWrite(data);
				stdout.flush();
			} catch (Exception e) {}
		});
	};
	socket.onClose = { if (exitOnClose) g_running = false; };
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