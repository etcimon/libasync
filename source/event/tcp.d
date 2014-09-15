module event.tcp;
import std.traits : isPointer;
import event.types;
import event.events;
import std.typecons : Tuple;

final class AsyncTCPConnection
{
package:

	EventLoop m_evLoop;

private:
	NetworkAddress m_peer;

nothrow:
	fd_t m_socket;
	bool m_noDelay;
	bool m_inbound;

public:
	this(EventLoop evl)
	in { assert(evl !is null); }
	body { m_evLoop = evl; }

	mixin DefStatus;

	@property bool isConnected() const {
		return m_socket != fd_t.init;
	}

	@property bool inbound() const {
		return m_inbound;
	}

	@property void noDelay(bool b)
	{
		if (m_socket == fd_t.init)
			m_noDelay = b;
		else
			setOption(TCPOption.NODELAY, true);
	}

	bool setOption(T)(TCPOption op, in T val) 
	in { assert(isConnected, "No socket to operate on"); }
	body {
		return m_evLoop.setOption(m_socket, op, val);
	}

	@property NetworkAddress peer() const 
	{
		return m_peer;
	}

	@property NetworkAddress local()
	in {
		assert(isConnected && m_peer != NetworkAddress.init, "Cannot get local address from a non-connected socket");
	}
	body {
		return m_evLoop.localAddr(m_socket, m_peer.ipv6);
	}

	@property void peer(NetworkAddress addr)
	in { 
		assert(!isConnected, "Cannot change remote address on a connected socket"); 
		assert(addr != NetworkAddress.init);
	}
	body {
		m_peer = addr;
	}

	typeof(this) host(string hostname, size_t port)
	in { 
		assert(!isConnected, "Cannot change remote address on a connected socket"); 
	}
	body {
		m_peer = m_evLoop.resolveHost(hostname, cast(ushort) port);
		return this;
	}

	typeof(this) ip(string ip, size_t port)
	in { 
		assert(!isConnected, "Cannot change remote address on a connected socket"); 
	}
	body {
		m_peer = m_evLoop.resolveIP(ip, cast(ushort) port);
		return this;
	}

	uint recv(ref ubyte[] ub)
	in { assert(isConnected, "No socket to operate on"); }
	body {
		return m_evLoop.recv(m_socket, ub);
	}

	uint send(in ubyte[] ub)
	in { assert(isConnected, "No socket to operate on"); }
	body {
		version(Posix)
			scope(exit)
				if (m_evLoop.status.code == Status.ASYNC)
					this.writeBlocked = true;
		return m_evLoop.send(m_socket, ub);
	}

	bool run(void delegate(TCPEvent) del) {
		TCPEventHandler handler;
		handler.del = del;
		handler.conn = this;
		return run(handler);
	}

	private bool run(TCPEventHandler del)
	in { assert(!isConnected); }
	body {
		m_socket = m_evLoop.run(this, del);
		if (m_socket == 0)
			return false;
		else
			return true;

	}

	bool kill(bool forced = false)
	in { assert(isConnected); }
	body {
		bool ret = m_evLoop.kill(this, forced);
		scope(exit) m_socket = 0;
		return ret;
	}

package:
	mixin TCPConnectionMixins;

	@property void inbound(bool b) {
		m_inbound = b;
	}

	@property bool noDelay() const
	{
		return m_noDelay;
	}

	@property fd_t socket() const {
		return m_socket;
	}

	@property void socket(fd_t sock) {
		m_socket = sock;
	}

}

final class AsyncTCPListener
{
private:
nothrow:
	EventLoop m_evLoop;
	fd_t m_socket;
	NetworkAddress m_local;
	bool m_noDelay;

public:

	this(EventLoop evl) { m_evLoop = evl; }

	mixin DefStatus;

	@property bool noDelay() const
	{
		return m_noDelay;
	}
	
	@property void noDelay(bool b) {
		if (m_socket == fd_t.init)
			m_noDelay = b;
		else
			assert(false, "Not implemented");
	}

	@property NetworkAddress local() const
	{
		return m_local;
	}

	@property void local(NetworkAddress addr)
	in { assert(m_socket == fd_t.init, "Cannot rebind a listening socket"); }
	body {
		m_local = addr;
	}

	typeof(this) host(string hostname, size_t port)
	in { assert(m_socket == fd_t.init, "Cannot rebind a listening socket"); }
	body {
		m_local = m_evLoop.resolveHost(hostname, cast(ushort) port);
		return this;
	}
	
	typeof(this) ip(string ip, size_t port)
	in { assert(m_socket == fd_t.init, "Cannot rebind a listening socket"); }
	body {
		m_local = m_evLoop.resolveIP(ip, cast(ushort) port);
		return this;
	}

	bool run(void delegate(TCPEvent) delegate(AsyncTCPConnection) del) {
		TCPAcceptHandler handler;
		handler.ctxt = this;
		handler.del = del;
		return run(handler);
	}

	private bool run(TCPAcceptHandler del)
	in { 
		assert(m_socket == fd_t.init, "Cannot rebind a listening socket");
		assert(m_local != NetworkAddress.init, "Cannot bind without an address. Please run .host() or .ip()");
	}
	body {
		m_socket = m_evLoop.run(this, del);
		if (m_socket == fd_t.init)
			return false;
		else
			return true;
	}
	
	bool kill()
	in { assert(m_socket != 0); }
	body {
		bool ret = m_evLoop.kill(this);
		return ret;
	}

package:
	version(Posix) mixin EvInfoMixins;

	@property fd_t socket() const {
		return m_socket;
	}
}

package struct TCPEventHandler {
	AsyncTCPConnection conn;

	/// Use getContext/setContext to persist the context in each activity. Using AsyncTCPConnection in args 
	/// allows the EventLoop implementation to create and pass a new object, which is necessary for listeners.
	void delegate(TCPEvent) del;

	void opCall(TCPEvent ev){
		assert(conn !is null, "Connection was disposed before shutdown could be completed");

		del(ev);

		/*debug {
			ubyte[1] test;
			ubyte[] testRef = test.ptr[0..1];
			assert(conn.recv(testRef) == 0 && conn.status.code == Status.ASYNC, "You must recv the whole buffer, because events are edge triggered!");
		}*/
		return;
	}
}

package struct TCPAcceptHandler {
	AsyncTCPListener ctxt;
	void delegate(TCPEvent) delegate(AsyncTCPConnection) del;

	TCPEventHandler opCall(AsyncTCPConnection conn){ // conn is null = error!
		assert(ctxt !is null);

		void delegate(TCPEvent) ev_handler = del(conn);
		TCPEventHandler handler;
		handler.del = ev_handler;
		handler.conn = conn;
		return handler;
	}
}

enum TCPEvent : char {
	ERROR = 0, // The connection will be forcefully closed, this is debugging information
	CONNECT, // indicates write will not block, although recv may or may not have data
	READ, // called once when new bytes are in the buffer
	WRITE, // only called when send returned Status.ASYNC
	CLOSE // The connection is being shutdown
}

enum TCPOption : char {
	NODELAY = 0,		// Don't delay send to coalesce packets
	REUSEADDR = 1,
	CORK,
	LINGER,
	BUFFER_RECV,
	BUFFER_SEND,
	TIMEOUT_RECV,
	TIMEOUT_SEND,
	TIMEOUT_HALFOPEN,
	KEEPALIVE_ENABLE,
	KEEPALIVE_DEFER,	// Start keeplives after this period
	KEEPALIVE_COUNT,	// Number of keepalives before death
	KEEPALIVE_INTERVAL,	// Interval between keepalives
	DEFER_ACCEPT,
	QUICK_ACK,			// Bock/reenable quick ACKs.
	CONGESTION
}