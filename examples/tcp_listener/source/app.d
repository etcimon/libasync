import event.d;
import std.stdio;

EventLoop g_evl;
TCPListener g_listener;
bool g_closed;

/// This example creates a listener on localhost:8081 which accepts connections, sends a reply, 
/// reads all packet buffers and exits the process after a client has disconnected
void main() {
	g_evl = new EventLoop;
	g_listener = new TCPListener("localhost", 8081);

	while(!g_closed)
		g_evl.loop();
}

class TCPListener {
	AsyncTCPListener m_listener;
	
	this(string host, size_t port) {
		TCPAcceptHandler accept_handler;
		accept_handler.ctxt = cast(void*) this;
		accept_handler.fct = (void* ctxt, AsyncTCPConnection conn) {
			auto listener = cast(TCPListener)ctxt;
			return listener.handler(conn);
		};

		m_listener = new AsyncTCPListener(g_evl);
		
		if (m_listener.host(host, port).run(accept_handler))
			writeln("Listening to ", m_listener.local.toString());
			
	}

	TCPEventHandler handler(AsyncTCPConnection conn) {
		TCPEventHandler tcp_handler;
		conn.setContext(new TCPConnection(conn));
		tcp_handler.conn = conn;
		tcp_handler.fct = (AsyncTCPConnection _conn, TCPEvent ev) {
			auto tcpConn = _conn.getContext!TCPConnection();
			return tcpConn.handler(ev);
		};
		
		return tcp_handler;
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