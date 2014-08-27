module event.test;
import event.events;
import std.stdio;
import std.datetime;

version(unittest):

unittest {
	cbCheck = new shared bool[17];

	lastTimer = Clock.currTime();
	start = Clock.currTime();
	evl = new EventLoop;
	writeln("Loading objects...");
	testOneshotTimer();
	testMultiTimer();
	tlsEvent = new shared AsyncSignal(evl);
	testSignal();
	testEvents();
	testTCPListen("localhost", 8080);
	testHTTPConnect();
	writeln("Loaded. Running event loop...");

	testTCPConnect("localhost", 8080);

	while(Clock.currTime() - start < 4.seconds) 
		evl.loop(100.msecs);
		
	int i;
	foreach (bool b; cbCheck) {
		assert(b, "Callback not triggered: cbCheck[" ~ i.to!string ~ "]");
		i++;
	}
	writeln("Callback triggers were successful, run time: ", Clock.currTime - start);
}

shared bool cbCheck[];
int cbTimerCnt;
SysTime lastTimer;

string message = "Some message here";
void testSignal() {
	NotifierHandler sh;
	AsyncNotifier as = new AsyncNotifier(evl);
	class StructCtxtTest {
		string title = "This is my title";
	}
	as.setContext(new StructCtxtTest);
	sh.ctxt = as;

	sh.fct = (AsyncNotifier signal) {
		auto ctxt = signal.getContext!(StructCtxtTest)();
		auto msg = *signal.getMessage!(string*)();
		static assert(is(typeof(ctxt) == StructCtxtTest));
		assert(ctxt.title == "This is my title");
		static assert(is(typeof(msg) == string));
		assert(msg == "Some message here");

		cbCheck[0] = true;

		return;
	};

	as.run(sh);
	as.trigger(&message);
}

void testEvents() {

	shared SignalHandler sh;
	sh.ctxt = tlsEvent;
	sh.fct = (shared AsyncSignal ev) {
		assert(ev.getMessage!(shared Msg*)().message is htls.message);
		cbCheck[1] = true;
	};
	tlsEvent.run(sh);

	shrEvent = new shared AsyncSignal(evl);
	
	shared SignalHandler sh2;
	sh2.ctxt = shrEvent;
	sh2.fct = (shared AsyncSignal ev) {
		assert(ev.getMessage!(shared Msg*)().message is hshr.message);
		cbCheck[2] = true;
	};
	shrEvent.run(sh2);

	testTLSEvent();

	import std.concurrency;
	Tid t2 = spawn(&testSharedEvent);
	import core.thread : Thread;
	while (!shrEvent2)
		Thread.sleep(100.msecs);
	shrEvent2.trigger(evl, hshr);
}

void testTLSEvent() {
	tlsEvent.trigger(htls);
}

void testSharedEvent() {
	EventLoop evl2 = new EventLoop;

	shrEvent2 = new shared AsyncSignal(evl2);
	shared SignalHandler sh2;
	sh2.ctxt = shrEvent2;
	sh2.fct = (shared AsyncSignal ev) {
		assert(ev.getMessage!(shared Msg*)().message is hshr.message);
		cbCheck[3] = true;
		return;
	};
	shrEvent2.run(sh2);
	shrEvent.trigger(evl2, hshr);
	while(Clock.currTime() - start < 1.seconds) 
		evl2.loop();
	shrEvent.trigger(evl2, hshr);
	while(Clock.currTime() - start < 4.seconds) 
		evl2.loop();
}

void testOneshotTimer() {	
	AsyncTimer at = new AsyncTimer(evl);
	at.oneShot = true;
	TimerHandler th;
	th.fct = (AsyncTimer ctxt) {
		assert(!cbCheck[4] && Clock.currTime() - start > 900.msecs && Clock.currTime() - start < 1100.msecs);
		assert(ctxt.id > 0);
		cbCheck[4] = true;
		
	};
	th.ctxt = at;
	at.run(th, 1.seconds);
}

void testMultiTimer() {	
	AsyncTimer at = new AsyncTimer(evl);
	at.oneShot = false;
	TimerHandler th;
	th.fct = (AsyncTimer ctxt) {
		assert(lastTimer !is SysTime.init && Clock.currTime() - lastTimer > 900.msecs && Clock.currTime() - lastTimer < 1100.msecs);
		assert(ctxt.id > 0);
		lastTimer = Clock.currTime();
		cbTimerCnt++;
		cbCheck[5] = true;
	};
	th.ctxt = at;
	at.run(th, 1.seconds);
}

TCPEventHandler handler(void* ptr, AsyncTCPConnection conn) {
	assert(ptr is null); // no context provided

	cbCheck[6] = true;
	TCPEventHandler evh;
	evh.conn = conn;
	evh.fct = &trafficHandler;

	return evh;
}

void trafficHandler(AsyncTCPConnection conn, TCPEvent ev){
	//// writeln("##TrafficHandler!");
	void doRead() {
		static ubyte[] bin = new ubyte[4092];
		while (true) {
			uint len = conn.recv(bin);
			// writeln("!!Server Received " ~ len.to!string ~ " bytes");
			// import std.file;
			if (len > 0) {
				auto res = cast(string)bin[0..len];
				if (res == "Client Hello")
					cbCheck[7] = true;
				if (res == "Client WRITEClient READ")
					cbCheck[8] = true;
				if (res == "Client READ")
					cbCheck[9] = true;
				if (res == "Client KILL")
					cbCheck[10] = true;
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
			cbCheck[11] = true;
			if (conn.socket != 0)
				conn.send(cast(ubyte[])"Server WRITE");
			break;
		case TCPEvent.CLOSE:
			cbCheck[12] = true;
			break;
		case TCPEvent.ERROR:
			// writeln("!!Server Error!");
			break;
	}
	
	return;
}

void testTCPListen(string ip, ushort port) {
	import event.memory;
	AsyncTCPListener listnr = new AsyncTCPListener(evl);

	auto addr = evl.resolveHost(ip, port);

	TCPAcceptHandler ach;
	ach.ctxt = null;
	ach.fct = &handler;

	auto success = listnr.run(ach, addr);
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
				cbCheck[14] = true;
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

					cbCheck[13] = true;
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
	AsyncTCPConnection conn = new AsyncTCPConnection(evl);

	Context ctxt = new Context;
	conn.setContext(ctxt);
	evh.conn = conn;
	conn.peer = evl.resolveHost(ip, port);
	
	auto success = conn.run(evh);
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
				cbCheck[15] = true;
				conn.send(cast(ubyte[])"GET http://example.org/\nHost: example.org\nConnection: close");
				break;
			case TCPEvent.READ:
				static ubyte[] bin = new ubyte[4092];
				while (true) {
					uint len = conn.recv(bin);
					cbCheck[16] = true;
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
	AsyncTCPConnection conn = new AsyncTCPConnection(evl);
	
	evh.conn = conn;
	conn.peer = evl.resolveHost("example.org", 80);
	
	conn.run(evh);
}

class Context {
	int writes;
}

EventLoop evl;
__gshared SysTime start;
shared AsyncSignal tlsEvent;
shared AsyncSignal shrEvent;
shared AsyncSignal shrEvent2;
struct Msg {
	string message;
}
shared Msg* hshr = new shared Msg("Hello from Shared!");
shared Msg* htls = new shared Msg("Hello from TLS!");
