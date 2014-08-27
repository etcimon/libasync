import event.d;
import std.stdio;

EventLoop g_evl;
TCPConnection g_tcpConnection;
bool g_closed;

/// This example creates a connection localhost:8081 and sends a message before closing
void main() {
	g_evl = new EventLoop;
	g_tcpConnection = new TCPConnection("localhost", 8081);

	while(!g_closed)
		g_evl.loop();
}

class TCPConnection {
	AsyncTCPConnection m_conn;
	
	this(string host, size_t port)
	{
		TCPEventHandler tcp_handler;
		m_conn = new AsyncTCPConnection(g_evl);
		m_conn.setContext(this);

		tcp_handler.conn = m_conn;
		tcp_handler.fct = (AsyncTCPConnection conn, TCPEvent ev) {
			TCPConnection This = conn.getContext!TCPConnection();
			return This.handler(ev);
		};

		m_conn.host(host, port).run(tcp_handler);
	}

	void onConnect() {
		onRead();
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
		m_conn.send(cast(ubyte[])"My Message");
		m_conn.kill();
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
				assert(false, m_conn.error());
		}
		return;
	}
	
}