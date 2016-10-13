module libasync.test;
version(unittest):
import libasync.events;
import std.stdio;
import std.datetime;
import libasync.file;
import std.conv : to;

AsyncDirectoryWatcher g_watcher;
shared AsyncDNS g_dns;


unittest {
	spawnAsyncThreads();
	scope(exit)
		destroyAsyncThreads();
	// writeln("Unit test started");
	g_cbCheck = new shared bool[19];
	g_lastTimer = Clock.currTime();
	gs_start = Clock.currTime();
	g_evl = getThreadEventLoop();
	g_evl.loop(1.msecs);
	// writeln("Loading objects...");
	testDirectoryWatcher();

	testDNS();
 	testOneshotTimer();
	testMultiTimer();
	gs_tlsEvent = new shared AsyncSignal(g_evl);
	testSignal();
	testEvents();
	testTCPListen("localhost", 8081);
	testHTTPConnect();
	// writeln("Loaded. Running event loop...");
	testFile();
	testTCPConnect("localhost", 8081);
	while(Clock.currTime() - gs_start < 7.seconds)
		g_evl.loop(100.msecs);

	int i;
	foreach (bool b; g_cbCheck) {
		assert(b, "Callback not triggered: g_cbCheck[" ~ i.to!string ~ "]");
		i++;
	}
	// writeln("Callback triggers were successful, run time: ", Clock.currTime - gs_start);

	assert(g_cbTimerCnt >= 3, "Multitimer expired only " ~ g_cbTimerCnt.to!string ~ " times"); // MultiTimer expired 3-4 times
	g_watcher.kill();
	g_notifier.kill();
	g_listnr.kill();
	version(LDC) {
		import core.stdc.stdlib; exit(0);
	}

}

StopWatch g_swDns;
void testDNS() {
	g_dns = new shared AsyncDNS(g_evl);
	g_swDns.start();
	g_dns.handler((NetworkAddress addr) {
		g_cbCheck[17] = true;
		// writeln("Resolved to: ", addr.toString(), ", it took: ", g_swDns.peek().usecs, " usecs");
	}).resolveHost("127.0.0.1");
}

void testDirectoryWatcher() {
	import std.file : mkdir, rmdir, exists;
	if (exists("./hey/tmp.tmp"))
		remove("./hey/tmp.tmp");
	if (exists("./hey"))
		rmdir("./hey");
	g_watcher = new AsyncDirectoryWatcher(g_evl);
	g_watcher.run({
		DWChangeInfo[1] change;
		DWChangeInfo[] changeRef = change.ptr[0..1];
		bool done;
		while(g_watcher.readChanges(changeRef))
		{
			g_cbCheck[18] = true;
			writeln(change);
			if (change[0].event == DWFileEvent.DELETED)
				done = true;
		}
	});
	g_watcher.watchDir(".");
	AsyncTimer tm = new AsyncTimer(g_evl);
	tm.duration(1.seconds).run({
		writeln("Creating directory ./hey");
		mkdir("./hey");
		assert(g_watcher.watchDir("./hey/"));
		tm.duration(1.seconds).run({
			static import std.file;
			writeln("Writing to ./hey/tmp.tmp for the first time");
			std.file.write("./hey/tmp.tmp", "some string");
			tm.duration(100.msecs).run({
				writeln("Removing ./hey/tmp.tmp");
				remove("./hey/tmp.tmp");
				tm.kill();
			});
		});
	});
}

void testFile() {
	gs_file = new shared AsyncFile(g_evl);

	{
		File file = File("test.txt", "w");
		file.rawWrite("This is the file content.");
		file.close();
	}
	gs_file.onReady({
		writeln("Created and wrote to test.txt through AsyncFile");
		auto file = gs_file;
		if (file.status.code == Status.ERROR)
			writeln("ERROR: ", file.status.text);
		import std.algorithm;
		if ((cast(string)file.buffer).startsWith("This is the file content.")) {
			g_cbCheck[7] = true;
		}
		else {
			//import std.stdio :  writeln;
			// writeln("ERROR: ", cast(string)file.buffer);
			assert(false);
		}
		import std.file : remove;
		gs_file.kill();
		remove("test.txt");
		writeln("Removed test.txt .. ");
	}).read("test.txt");

}


void testSignal() {
	g_notifier = new AsyncNotifier(g_evl);
	auto title = "This is my title";

	void delegate() del = {
		import std.stdio;
		assert(title == "This is my title");
		g_cbCheck[0] = true;

		return;
	};

	g_notifier.run(del);
	g_notifier.trigger(); // will be completed in the event loop
}

void testEvents() {

	gs_tlsEvent.run({
		assert(g_message == "Some message here");
		g_cbCheck[1] = true;
	});

	gs_shrEvent = new shared AsyncSignal(g_evl);

	gs_shrEvent.run({
		assert(gs_hshr.message == "Hello from shared!");
		g_cbCheck[2] = true;
	});

	testTLSEvent();

	import std.concurrency;
	Tid t2 = spawn(&testSharedEvent);
	import core.thread : Thread;
	while (!gs_shrEvent2 || gs_shrEvent2.id == 0)
		Thread.sleep(100.msecs);

	gs_shrEvent2.trigger(g_evl);
}

void testTLSEvent() {
	gs_tlsEvent.trigger();
}

void testSharedEvent() {
	EventLoop evl2 = new EventLoop;

	gs_shrEvent2 = new shared AsyncSignal(evl2);
	gs_shrEvent2.run({
		g_cbCheck[3] = true;
		return;
	});

	gs_shrEvent.trigger(evl2);

	while(Clock.currTime() - gs_start < 1.seconds)
		evl2.loop();

	gs_shrEvent.trigger(evl2);

	while(Clock.currTime() - gs_start < 4.seconds)
		evl2.loop();
}

void testOneshotTimer() {
	AsyncTimer g_timerOneShot = new AsyncTimer(g_evl);
	g_timerOneShot.duration(1.seconds).run({
		assert(!g_cbCheck[4] && Clock.currTime() - gs_start > 900.msecs && Clock.currTime() - gs_start < 1100.msecs);
		assert(g_timerOneShot.id != 0);
		g_cbCheck[4] = true;

	});
}

void testMultiTimer() {
	AsyncTimer g_timerMulti = new AsyncTimer(g_evl);
	g_timerMulti.periodic().duration(1.seconds).run({
		assert(g_lastTimer !is SysTime.init && Clock.currTime() - g_lastTimer > 900.msecs && Clock.currTime() - g_lastTimer < 1100.msecs);
		assert(g_timerMulti.id > 0);
		assert(!g_timerMulti.oneShot);
		g_lastTimer = Clock.currTime();
		g_cbTimerCnt++;
		g_cbCheck[5] = true;
	});

}


void trafficHandler(TCPEvent ev){
	// writeln("##TrafficHandler!");
	void doRead() {
		static ubyte[] bin = new ubyte[4092];
		while (true) {
			uint len = g_conn.recv(bin);
			// writeln("!!Server Received " ~ len.to!string ~ " bytes");
			// import std.file;
			if (len > 0) {
				auto res = cast(string)bin[0..len];
				// writeln(res);
				import std.algorithm : canFind;
				if (res.canFind("Client Hello"))
					g_cbCheck[8] = true;

				if (res.canFind("Client WRITE"))
					g_cbCheck[8] = false;

				if (res.canFind("Client READ"))
					g_cbCheck[9] = true;

				if (res.canFind("Client KILL"))
					g_cbCheck[10] = true;
			}
			if (len < bin.length)
				break;
		}
	}

	final switch (ev) {
		case TCPEvent.CONNECT:
			// writeln("!!Server Connected");
			doRead();
			if (g_conn.socket != 0)
				g_conn.send(cast(ubyte[])"Server Connect");
			break;
		case TCPEvent.READ:
			// writeln("!!Server Read is ready");
			g_cbCheck[11] = true;
			if (g_conn.socket != 0)
				g_conn.send(cast(ubyte[])"Server READ");
			doRead();
			break;
		case TCPEvent.WRITE:
			// writeln("!!Server Write is ready");
			if (g_conn.socket != 0)
				g_conn.send(cast(ubyte[])"Server WRITE");
			break;
		case TCPEvent.CLOSE:
			doRead();
			// writeln("!!Server Disconnect!");
			g_cbCheck[12] = true;
			break;
		case TCPEvent.ERROR:
			// writeln("!!Server Error!");
			break;
	}

	return;
}

void testTCPListen(string ip, ushort port) {

	g_listnr = new AsyncTCPListener(g_evl);

	void delegate(TCPEvent) handler(AsyncTCPConnection conn) {
		g_conn = conn;
		g_cbCheck[6] = true;
		import std.functional : toDelegate;
		return toDelegate(&trafficHandler);
	}

	auto success = g_listnr.host(ip, port).run(&handler);
	assert(success, g_listnr.error);
}

void testTCPConnect(string ip, ushort port) {
	auto conn = new AsyncTCPConnection(g_evl);
	conn.peer = g_evl.resolveHost(ip, port);

	void delegate(TCPEvent) connHandler = (TCPEvent ev){
		void doRead() {
			static ubyte[] bin = new ubyte[4092];
			while (true) {
				assert(conn.socket > 0);
				uint len = conn.recv(bin);
				// writeln("!!Client Received " ~ len.to!string ~ " bytes");
				// if (len > 0)
					// writeln(cast(string)bin[0..len]);
				if (len < bin.length)
					break;
			}
		}
		final switch (ev) {
			case TCPEvent.CONNECT:
				// writeln("!!Client Connected");
				conn.setOption(TCPOption.QUICK_ACK, true);
				conn.setOption(TCPOption.NODELAY, true);
				g_cbCheck[14] = true;
				if (conn.socket != 0)
					conn.send(cast(ubyte[])"Client Hello");
				assert(conn.socket > 0);
				break;
			case TCPEvent.READ:
				// writeln("!!Client Read is ready at writes: ", g_writes);
				doRead();

				// respond
				g_writes += 1;
				if (g_writes > 3) {
					if (conn.socket != 0)
						conn.send(cast(ubyte[])"Client KILL");
					conn.kill();

					g_cbCheck[13] = true;
				}
				else
					if (conn.socket != 0)
						conn.send(cast(ubyte[])"Client READ");

				break;
			case TCPEvent.WRITE:

				g_writes += 1;
				// writeln("!!Client Write is ready");
				if (conn.socket != 0)
					conn.send(cast(ubyte[])"Client WRITE");
				break;
			case TCPEvent.CLOSE:
				// writeln("!!Client Disconnected");
				break;
			case TCPEvent.ERROR:
				// writeln("!!Client Error!");
				break;
		}
		return;
	};

	auto success = conn.run(connHandler);
	assert(success);

}

void testHTTPConnect() {
	auto conn = new AsyncTCPConnection(g_evl);
	conn.peer = g_evl.resolveHost("example.org", 80);

	auto del = (TCPEvent ev){
		final switch (ev) {
			case TCPEvent.CONNECT:
				// writeln("!!Connected");
				static ubyte[] abin = new ubyte[4092];
				while (true) {
					uint len = conn.recv(abin);
					if (len < abin.length)
						break;
				}
				g_cbCheck[15] = true;
				// writeln(conn.local.toString());
				// writeln(conn.peer.toString());
				conn.send(cast(ubyte[])"GET http://example.org/\nHost: example.org\nConnection: close");
				break;
			case TCPEvent.READ:
				static ubyte[] bin = new ubyte[4092];
				while (true) {
					uint len = conn.recv(bin);
					g_cbCheck[16] = true;
					// writeln("!!Received " ~ len.to!string ~ " bytes");
					if (len < bin.length)
						break;
				}
				break;
			case TCPEvent.WRITE:
				// writeln("!!Write is ready");
				break;
			case TCPEvent.CLOSE:
				// writeln("!!Disconnected");
				break;
			case TCPEvent.ERROR:
				// writeln("!!Error!");
				break;
		}
		return;
	};


	conn.run(del);
}

EventLoop g_evl;
AsyncTimer g_timerOneShot;
AsyncTimer g_timerMulti;
AsyncTCPConnection g_tcpConnect;
AsyncTCPConnection g_httpConnect;
AsyncTCPConnection g_conn; // incoming
AsyncNotifier g_notifier;
AsyncTCPListener g_listnr;
shared AsyncSignal gs_tlsEvent;
shared AsyncSignal gs_shrEvent;
shared AsyncSignal gs_shrEvent2;
shared AsyncFile gs_file;
__gshared SysTime gs_start;
string g_message = "Some message here";
shared Msg* gs_hshr = new shared Msg("Hello from shared!");
shared bool[] g_cbCheck;
int g_cbTimerCnt;
int g_writes;
SysTime g_lastTimer;

shared struct Msg {
	string message;
}
