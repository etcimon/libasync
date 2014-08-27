module event.test;
version(unittest):
import event.events;
import std.stdio;
import std.datetime;

AsyncTimer g_timerOneShot;
AsyncTimer g_timerMulti;
AsyncTCPConnection g_tcpConnect;
AsyncTCPConnection g_httpConnect;
EventLoop g_evl;
AsyncNotifier g_notifier;
AsyncTCPListener g_listnr;
__gshared SysTime gs_start;
shared AsyncSignal gs_tlsEvent;
shared AsyncSignal gs_shrEvent;
shared AsyncSignal gs_shrEvent2;
string g_message = "Some message here";
shared Msg* gs_hshr = new shared Msg("Hello from Shared!");
shared Msg* gs_htls = new shared Msg("Hello from TLS!");
shared bool g_cbCheck[];
int g_cbTimerCnt;
SysTime g_lastTimer;

unittest {
	g_cbCheck = new shared bool[17];
	g_lastTimer = Clock.currTime();
	gs_start = Clock.currTime();
	g_evl = new EventLoop;
	writeln("Loading objects...");
	testOneshotTimer();
	testMultiTimer();
	gs_tlsEvent = new shared AsyncSignal(g_evl);
	testSignal();
	testEvents();
	testTCPListen("localhost", 8080);
	testHTTPConnect();
	writeln("Loaded. Running event loop...");

	testTCPConnect("localhost", 8080);

	while(Clock.currTime() - gs_start < 4.seconds) 
		g_evl.loop(100.msecs);
		
	int i;
	foreach (bool b; g_cbCheck) {
		assert(b, "Callback not triggered: g_cbCheck[" ~ i.to!string ~ "]");
		i++;
	}
	writeln("Callback triggers were successful, run time: ", Clock.currTime - gs_start);
	assert(g_cbTimerCnt == 4); // MultiTimer expired 4 times

	g_listnr.kill();
}

void testSignal() {
	NotifierHandler sh;
	g_notifier = new AsyncNotifier(g_evl);
	class StructCtxtTest {
		string title = "This is my title";
	}
	g_notifier.setContext(new StructCtxtTest);
	sh.ctxt = g_notifier;

	sh.fct = (AsyncNotifier signal) {
		import std.stdio;
		auto ctxt = signal.getContext!(StructCtxtTest)();
		auto msg = *signal.getMessage!(string*)();
		static assert(is(typeof(ctxt) == StructCtxtTest));
		assert(ctxt.title == "This is my title");
		static assert(is(typeof(msg) == string));
		assert(msg == "Some message here");

		g_cbCheck[0] = true;

		return;
	};

	g_notifier.run(sh);

	g_notifier.trigger(&g_message);
}

void testEvents() {

	shared SignalHandler sh;
	sh.ctxt = gs_tlsEvent;
	sh.fct = (shared AsyncSignal ev) {
		assert(ev.getMessage!(shared Msg*)().message is gs_htls.message);
		g_cbCheck[1] = true;
	};
	gs_tlsEvent.run(sh);

	gs_shrEvent = new shared AsyncSignal(g_evl);
	
	shared SignalHandler sh2;
	sh2.ctxt = gs_shrEvent;
	sh2.fct = (shared AsyncSignal ev) {
		assert(ev.getMessage!(shared Msg*)().message is gs_hshr.message);
		g_cbCheck[2] = true;
	};
	gs_shrEvent.run(sh2);

	testTLSEvent();

	import std.concurrency;
	Tid t2 = spawn(&testSharedEvent);
	import core.thread : Thread;
	while (!gs_shrEvent2 || gs_shrEvent2.id == 0)
		Thread.sleep(100.msecs);

	gs_shrEvent2.trigger(g_evl, gs_hshr);
}

void testTLSEvent() {
	gs_tlsEvent.trigger(gs_htls);
}

void testSharedEvent() {
	EventLoop evl2 = new EventLoop;

	gs_shrEvent2 = new shared AsyncSignal(evl2);
	shared SignalHandler sh2;
	sh2.ctxt = gs_shrEvent2;
	sh2.fct = (shared AsyncSignal ev) {
		assert(ev.getMessage!(shared Msg*)().message is gs_hshr.message);
		g_cbCheck[3] = true;
		return;
	};
	gs_shrEvent2.run(sh2);
	gs_shrEvent.trigger(evl2, gs_hshr);
	while(Clock.currTime() - gs_start < 1.seconds) 
		evl2.loop();
	gs_shrEvent.trigger(evl2, gs_hshr);
	while(Clock.currTime() - gs_start < 4.seconds) 
		evl2.loop();
}

void testOneshotTimer() {	
	AsyncTimer g_timerOneShot = new AsyncTimer(g_evl);
	g_timerOneShot.oneShot = true;
	TimerHandler th;
	th.fct = (AsyncTimer ctxt) {
		assert(!g_cbCheck[4] && Clock.currTime() - gs_start > 900.msecs && Clock.currTime() - gs_start < 1100.msecs);
		assert(ctxt.id > 0);
		g_cbCheck[4] = true;
		
	};
	th.ctxt = g_timerOneShot;
	assert(g_timerOneShot.run(th, 1.seconds), g_timerOneShot.status.code.to!string ~ ": " ~ g_timerOneShot.status.text ~ " | " ~ g_timerOneShot.error);
}

void testMultiTimer() {	
	AsyncTimer g_timerMulti = new AsyncTimer(g_evl);
	g_timerMulti.oneShot = false;
	TimerHandler th;
	th.fct = (AsyncTimer ctxt) {
		assert(g_lastTimer !is SysTime.init && Clock.currTime() - g_lastTimer > 900.msecs && Clock.currTime() - g_lastTimer < 1100.msecs);
		assert(ctxt.id > 0);
		assert(!ctxt.oneShot);
		g_lastTimer = Clock.currTime();
		g_cbTimerCnt++;
		g_cbCheck[5] = true;
	};
	th.ctxt = g_timerMulti;
	assert(g_timerMulti.run(th, 1.seconds), g_timerOneShot.status.code.to!string ~ ": " ~ g_timerOneShot.status.text ~ " | " ~ g_timerOneShot.error);
}

TCPEventHandler handler(void* ptr, AsyncTCPConnection conn) {
	assert(ptr is null); // no context provided

	g_cbCheck[6] = true;
	TCPEventHandler evh;
	evh.conn = conn;
	evh.fct = &trafficHandler;

	return evh;
}

void trafficHandler(AsyncTCPConnection conn, TCPEvent ev){
	//writeln("##TrafficHandler!");
	void doRead() {
		static ubyte[] bin = new ubyte[4092];
		while (true) {
			uint len = conn.recv(bin);
			// writeln("!!Server Received " ~ len.to!string ~ " bytes");
			// import std.file;
			if (len > 0) {
				auto res = cast(string)bin[0..len];
				//writeln(res);
				if (res == "Client Hello")
					g_cbCheck[7] = true;
				if (res == "Client WRITEClient READ")
					g_cbCheck[8] = true;
				if (res == "Client READClient WRITE")
					g_cbCheck[8] = true;
				if (res == "Client READClient WRITEClient READClient WRITE") {
					g_cbCheck[8] = true;
					g_cbCheck[9] = true;
				}
				if (res == "Client READ")
					g_cbCheck[9] = true;
				if (res == "Client KILL")
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
			if (conn.socket != 0)
				conn.send(cast(ubyte[])"Server Connect");
			break;
		case TCPEvent.READ:
			// writeln("!!Server Read is ready");
			if (conn.socket != 0)
				conn.send(cast(ubyte[])"Server READ");
			doRead();
			break;
		case TCPEvent.WRITE:
			// writeln("!!Server Write is ready");
			g_cbCheck[11] = true;
			if (conn.socket != 0)
				conn.send(cast(ubyte[])"Server WRITE");
			break;
		case TCPEvent.CLOSE:
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

	TCPAcceptHandler ach;
	ach.ctxt = null;
	ach.fct = &handler;

	auto success = g_listnr.host(ip, port).run(ach);
	assert(success);
}

void testTCPConnect(string ip, ushort port) {
	TCPEventHandler evh;
	evh.fct = (AsyncTCPConnection conn, TCPEvent ev){
		void doRead() {
			static ubyte[] bin = new ubyte[4092];
			while (true) {
				assert(conn.socket > 0);
				uint len = conn.recv(bin);
				// writeln("!!Client Received " ~ len.to!string ~ " bytes");
				//if (len > 0)
				//	writeln(cast(string)bin[0..len]);
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
				// writeln("!!Client Read is ready");
				doRead();

				// respond
				Context ctxt = conn.getContext!(Context)();
				ctxt.writes += 1;
				if (ctxt.writes > 3) {
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
				Context ctxt = conn.getContext!(Context)();
				ctxt.writes += 1;
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

	import event.memory;
	g_tcpConnect = new AsyncTCPConnection(g_evl);

	Context ctxt = new Context;
	g_tcpConnect.setContext(ctxt);
	evh.conn = g_tcpConnect;
	g_tcpConnect.peer = g_evl.resolveHost(ip, port);

	auto success = g_tcpConnect.run(evh);
	assert(success);

}

void testHTTPConnect() {
	TCPEventHandler evh;
	evh.fct = (AsyncTCPConnection conn, TCPEvent ev){
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
	g_httpConnect = new AsyncTCPConnection(g_evl);
	
	evh.conn = g_httpConnect;
	g_httpConnect.peer = g_evl.resolveHost("example.org", 80);
	
	g_httpConnect.run(evh);
}

class Context {
	int writes;
}

struct Msg {
	string message;
}