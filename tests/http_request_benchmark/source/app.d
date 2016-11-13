
// Use these to avoid reaching maximum amount of open sockets:
// # echo 1 > /proc/sys/net/ipv4/tcp_tw_recycle
// # echo 1 > /proc/sys/net/ipv4/tcp_tw_reuse
// # echo 2 > /proc/sys/net/ipv4/tcp_fin_timeout

import core.time;

import std.datetime : Clock;
import std.string : format;
import std.stdio : stderr, File;
import std.file : mkdirRecurse;
import std.exception : enforce, collectException;
import std.traits : isInstanceOf;

import memutils.circularbuffer : CircularBuffer;

import libasync;

immutable HTTPRequest = "GET / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nAccept: */*\r\nConnection: Close\r\n\r\n";

immutable getServerAddress = {
	import std.socket : InternetAddress;
	return NetworkAddress(new InternetAddress("127.0.0.1", 8080));
};

immutable bufferSize = 64 * 1024;
immutable repetitions = 1 << 12;
immutable averageWindowSize = 1000;

version (Windows)      immutable dataPath = "results/windows";
else version (linux)   immutable dataPath = "results/linux";
else version (OSX)     immutable dataPath = "results/osx";
else version (FreeBSD) immutable dataPath = "results/freebsd";
else                   immutable dataPath = "results/unknown";

immutable dataFilenameFormat = dataPath ~ "/runtimes_%s.dat";

EventLoop g_eventLoop = void;
bool g_running = void;

void main()
{
	mkdirRecurse(dataPath);

	auto serverAddress = getServerAddress();
	g_eventLoop = getThreadEventLoop();

	auto dataFile = File(dataFilenameFormat.format(Clock.currTime.toISOString()), "w");

	foreach (i; 0..repetitions) {
		auto client = doSetup_AsyncSocket(serverAddress);
		g_running = true;
		dataFile.writefln("%s %s", i, measure!loopUntilDone.total!"nsecs");
	}

	dataFile.writeln();
	dataFile.writeln();

	foreach (i; 0..repetitions) {
		auto client = doSetup_AsyncTCPConnection(serverAddress);
		g_running = true;
		dataFile.writefln("%s %s", i, measure!loopUntilDone.total!"nsecs");
	}
}

auto measure(alias fun, Args...)(Args args)
{
	auto before = MonoTime.currTime;
	fun(args);
	auto after = MonoTime.currTime;
	return after - before;
}

pragma(inline, true)
void loopUntilDone()
{ while (g_running) g_eventLoop.loop(-1.seconds); }

auto doSetup_AsyncSocket(NetworkAddress to)
{
	import libasync.internals.socket_compat : AF_INET;

	auto client = new AsyncSocket(g_eventLoop, AF_INET, SocketType.STREAM);

	static recvBuf = new ubyte[bufferSize];

	client.onConnect = {
		client.receiveContinuously = true;          // Start continuous receive mode with next receive call
		client.receive(recvBuf, (data) {});         // Ignore the HTTP Response
		client.send(cast(ubyte[]) HTTPRequest, {}); // Send the HTTP Request, do nothing once it was sent
	};

	client.onClose = { g_running = false; };

	client.onError = {
		stderr.writeln("Socket operation failed: ", client.error).collectException();
		g_running = false;
	};

	enforce(client.run(), "Failed to create socket: " ~ client.error);
	enforce(client.connect(to), "Failed to start connecting: " ~ client.error);

	return client;
}

auto doSetup_AsyncTCPConnection(NetworkAddress to)
{
	auto client = new AsyncTCPConnection(g_eventLoop);
	client.peer = to;

	void onRead() {
		static recvBuf = new ubyte[bufferSize];
		uint recvCount = void;

		do {
			recvCount = client.recv(recvBuf);
		} while (recvCount > 0);
	}

	void onWrite() {
		client.send(cast(ubyte[]) HTTPRequest);
	}

	void onConnect() {
		onRead();
		onWrite();
	}

	void onClose() { g_running = false; }

	void handler(TCPEvent ev) {

		try final switch (ev) {
			case TCPEvent.CONNECT:
				onConnect();
				break;
			case TCPEvent.READ:
				onRead();
				break;
			case TCPEvent.WRITE:
				//onWrite();
				break;
			case TCPEvent.CLOSE:
				onClose();
				break;
			case TCPEvent.ERROR:
				assert(false, client.error());
		} catch (Exception e) {
			assert(false, e.toString());
		}
		return;
	}

	enforce(client.run(&handler), "Failed to create connection: " ~ client.error);

	return client;
}