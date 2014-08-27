module event.test;
import event.events;
import std.stdio;
import std.datetime;

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

unittest {
	//import etc.linux.memoryerror;
	//version(linux)
	//	registerMemoryErrorHandler();
	start = Clock.currTime();
	evl = new EventLoop;
	testTimer();
	// writeln("Timer added");

	tlsEvent = new shared AsyncSignal(evl);

	testSignal();
	// writeln("Signal succeeded");
	testEvents();
	// writeln("Events succeeded");
	testTCPListen("localhost", 8080);
	// writeln("Added listener");
	bool second;
	while(Clock.currTime() - start < 3.seconds) {
		evl.loop();

		if (Clock.currTime() - start > 2.seconds && !second){
			testTCPConnect("localhost", 8080);
			// writeln("Connecting");
			second = true;
		}
	}

	testHTTPConnect();

	while(Clock.currTime() - start < 4.seconds) 
		evl.loop();
		
}

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
		// writeln("Context: ", ctxt.title);
		// writeln("Message: ", msg);
		return;
	};

	as.run(sh);
	as.trigger(&message);
}

void testEvents() {

	shared SignalHandler sh;
	sh.ctxt = tlsEvent;
	sh.fct = (shared AsyncSignal ev) {
		// writeln(ev.getMessage!(shared Msg*)().message);
	};
	tlsEvent.run(sh);

	shrEvent = new shared AsyncSignal(evl);
	
	shared SignalHandler sh2;
	sh2.ctxt = shrEvent;
	sh2.fct = (shared AsyncSignal ev) {
		// writeln(ev.getMessage!(shared Msg*)().message);
	};
	shrEvent.run(sh2);

	testTLSEvent();

	import std.concurrency;
	Tid t2 = spawn(&testSharedEvent);
	import core.thread : Thread;
	Thread.sleep(1.seconds);

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
		// writeln(ev.getMessage!(shared Msg*)().message);
	};
	shrEvent2.run(sh2);
	shrEvent.trigger(evl2, hshr);
	while(Clock.currTime() - start < 1.seconds) 
		evl2.loop();
	shrEvent.trigger(evl2, hshr);
	while(Clock.currTime() - start < 4.seconds) 
		evl2.loop();
}

void testTimer() {	
	AsyncTimer at = new AsyncTimer(evl);
	at.oneShot = false;
	TimerHandler th;
	th.fct = (AsyncTimer ctxt) {
		// writeln("Timer (1s) callback triggered at: ", (Clock.currTime() - start).toString());
	};
	th.ctxt = at;
	at.run(th, 1.seconds);


}

TCPEventHandler handler(void* ptr, AsyncTCPConnection conn) {
	assert(ptr is null);
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
			import std.file;
			if (len > 0)
				// writeln(cast(string)bin[0..len]);
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
			if (conn.socket != 0)
				conn.send(cast(ubyte[])"Server WRITE");
			break;
		case TCPEvent.CLOSE:
			// writeln("!!Server Disconnected");
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
				uint len = conn.recv(bin);
				// writeln("!!Client Received " ~ len.to!string ~ " bytes");
				if (len > 0)
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
				if (conn.socket != 0)
					conn.send(cast(ubyte[])"Client Hello");
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
					// writeln("!!Received " ~ len.to!string ~ " bytes");
					import std.file;
					File file = File("index.html", "a");
					if (len > 0)
						file.write(cast(string)abin[0..len]);
					if (len < abin.length)
						break;
				}
				conn.send(cast(ubyte[])"GET http://example.org/\nHost: example.org\nConnection: close");
				break;
			case TCPEvent.READ:
				static ubyte[] bin = new ubyte[4092];
				while (true) {
					uint len = conn.recv(bin);
					// writeln("!!Received " ~ len.to!string ~ " bytes");
					import std.file;
					File file = File("index.html", "a");
					if (len > 0)
						file.write(cast(string)bin[0..len]);
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