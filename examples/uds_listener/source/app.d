
import libasync;

/// This example creates a listener at /tmp/libasync_uds.sock,
/// continuously accepts connections, and periodically (1 second) sends
/// a pseudo-random number in the interval [0,99] to each connected client
void main(string[] args)
{
	g_eventLoop = getThreadEventLoop();
	g_listener = new UDSListener(new UnixAddress("/tmp/libasync_uds.sock"));

	while(!g_closed) g_eventLoop.loop(-1.seconds);
}

EventLoop g_eventLoop = void;
UDSListener g_listener = void;
bool g_closed;

class UDSListener {
	AsyncUDSListener m_listener;

	this(UnixAddress address) {
		m_listener = new AsyncUDSListener(g_eventLoop);
		m_listener.local = address;
		if (m_listener.run(&handler)) {
			writeln("Listening to ", m_listener.local.toString());
		}
	}

	void delegate(EventCode) handler(AsyncUDSConnection conn) nothrow {
		auto udsConn = new UDSConnection(conn);
		return &udsConn.handler;
	}
}

class UDSConnection {
	AsyncUDSConnection m_conn;
	AsyncTimer m_generator;

	this(AsyncUDSConnection conn) nothrow
	{
		m_conn = conn;
	}

	void onConnect() {
		writeln("Client connected");
		m_generator = new AsyncTimer(g_eventLoop);
		m_generator.duration = 1.seconds;
		m_generator.periodic = true;
		m_generator.run({
			m_conn.send(cast(ubyte[]) "%d".format(uniform(0, 100)));
		});
	}

	// NOTE: All buffers must be empty when returning from TCPEvent.READ
	void onRead() {
		static buffer = new ubyte[4096];
		uint read = void;
		while ((read = m_conn.recv(buffer)) >= buffer.length) {
			writeln("Received data: ", cast(string) buffer[0 .. read]);
		}
	}

	void onWrite() {
		writeln("OS send buffer ready");
	}

	void onClose() {
		writeln("Client disconnected");
		m_generator.kill();
		m_conn.kill();
	}

	void handler(EventCode code) {
		final switch (code) with (EventCode) {
			case CONNECT:
				onConnect();
				break;
			case READ:
				onRead();
				break;
			case WRITE:
				onWrite();
				break;
			case CLOSE:
				onClose();
				break;
			case ERROR:
				assert(false, "Error during UDS Event");
		}
		return;
	}
}

shared static ~this() {
	destroyAsyncThreads();
}

import core.time;
import std.stdio;
import std.format;
import std.random;
