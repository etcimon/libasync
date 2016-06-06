
import libasync;

/// This example creates a client connecting to /tmp/libasync_uds.sock,
/// then forwarding everything it receives to STDOUT, shutting itself
/// down after ten seconds.
void main(string[] args)
{
	g_eventLoop = getThreadEventLoop();
	auto client = new UDSClient(new UnixAddress("/tmp/libasync_uds.sock"));

	while(!g_closed) g_eventLoop.loop(-1.seconds);
}

EventLoop g_eventLoop = void;
bool g_closed;

class UDSClient {
	AsyncUDSConnection m_conn;
	AsyncTimer m_killer;

	this(UnixAddress peer) nothrow
	{
		m_conn = new AsyncUDSConnection(g_eventLoop);
		m_conn.peer = peer;
		m_conn.run(&handler);
	}

	void onConnect() {
		writeln("Connected");
		m_killer = new AsyncTimer(g_eventLoop);
		m_killer.duration = 10.seconds;
		m_killer.periodic = false;
		m_killer.run({
			m_killer.kill();
			m_conn.kill();
			g_closed = true;
		});
	}

	// NOTE: All buffers must be empty when returning from TCPEvent.READ
	void onRead() {
		static buffer = new ubyte[4096];
		uint read = void;
		do {
			read = m_conn.recv(buffer);
			writefln("Received %d bytes:", read);
			writeln(cast(string) buffer[0 .. read]);
		} while (read >= buffer.length);
	}

	void onWrite() {
		writeln("OS send buffer ready");
	}

	void onClose() {
		writeln("Disconnected");
		m_killer.kill();
		m_conn.kill();
		g_closed = true;
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
