import libasync;
import std.stdio;

EventLoop g_evl;
TCPListener g_listener;
bool g_closed;

/// This example creates a listener on localhost:8081 which accepts connections, sends a reply,
/// and exits the process after the first client has disconnected
void main() {
	g_evl = new EventLoop;
	g_listener = new TCPListener("localhost", 8081);

	while(!g_closed)
		g_evl.loop();
	destroyAsyncThreads();
}

class TCPListener {
	AsyncTCPListener m_listener;

	this(string host, size_t port) {
		m_listener = new AsyncTCPListener(g_evl);
		if (m_listener.host(host, port).run(&handler))
			writeln("Listening to ", m_listener.local.toString());

	}

	void delegate(TCPEvent) handler(AsyncTCPConnection conn) {
		auto tcpConn = new TCPConnection(conn);
		return &tcpConn.handler;
	}

}

class TCPConnection {
	AsyncTCPConnection m_conn;

	this(AsyncTCPConnection conn)
	{
		this.m_conn = conn;
	}
	void onConnect() {
		onRead();
		onWrite();
	}

	// Note: All buffers must be empty when returning from TCPEvent.READ
	void onRead() {
		static ubyte[] bin = new ubyte[4092];
		while (true) {
			uint len = m_conn.recv(bin);

			if (len > 0) {
				auto res = cast(string)bin[0..len];
				writeln("Received data: ", res);
			}
			if (len < bin.length)
				break;
		}
	}

	void onWrite() {
		m_conn.send(cast(ubyte[])"My Reply");
		writeln("Sent: My Reply");
	}

	void onClose() {
		writeln("Connection closed");
		g_closed = true;
	}

	void handler(TCPEvent ev) {
		final switch (ev) {
			case TCPEvent.CONNECT:
				onConnect();
				break;
			case TCPEvent.READ:
				onRead();
				break;
			case TCPEvent.WRITE:
				onWrite();
				break;
			case TCPEvent.CLOSE:
				onClose();
				break;
			case TCPEvent.ERROR:
				assert(false, "Error during TCP Event");
		}
		return;
	}

}
