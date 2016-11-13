///
module libasync.tcp;
import std.traits : isPointer;
import libasync.types;
import libasync.events;
import std.typecons : Tuple;

/// Wraps a TCP stream between 2 network adapters, using a custom handler to
/// signal related events. Many of these objects can be active concurrently
/// in a thread if the event loop is running and the handlers do not block.
final class AsyncTCPConnection
{
package:
	EventLoop m_evLoop;

private:
	NetworkAddress m_peer;

nothrow:
	fd_t m_socket;
	fd_t m_preInitializedSocket;
	bool m_noDelay;
	bool m_inbound;
public:
	///
	this(EventLoop evl, fd_t preInitializedSocket = fd_t.init)
	in { assert(evl !is null); }
	body {
		m_evLoop = evl;
		m_preInitializedSocket = preInitializedSocket;
	}

	mixin DefStatus;

	/// Returns false if the connection has gone.
	@property bool isConnected() const {
		return m_socket != fd_t.init;
	}

	/// Returns true if this connection was accepted by an AsyncTCPListener instance.
	@property bool inbound() const {
		return m_inbound;
	}

	/// Disables(true)/enables(false) nagle's algorithm (default:enabled).
	@property void noDelay(bool b)
	{
		if (m_socket == fd_t.init)
			m_noDelay = b;
		else
			setOption(TCPOption.NODELAY, true);
	}

	/// Changes the default OS configurations for this underlying TCP Socket.
	bool setOption(T)(TCPOption op, in T val)
	in { assert(isConnected, "No socket to operate on"); }
	body {
		return m_evLoop.setOption(m_socket, op, val);
	}

	/// Returns the OS-specific structure of the internet address
	/// of the remote network adapter
	@property NetworkAddress peer() const
	{
		return m_peer;
	}

	/// Returns the OS-specific structure of the internet address
	/// for the local end of the connection.
	@property NetworkAddress local()
	in {
		assert(isConnected && m_peer != NetworkAddress.init, "Cannot get local address from a non-connected socket");
	}
	body {
		return m_evLoop.localAddr(m_socket, m_peer.ipv6);
	}

	/// Sets the remote address as an OS-specific structure (only usable before connecting).
	@property void peer(NetworkAddress addr)
	in {
		assert(!isConnected, "Cannot change remote address on a connected socket");
		assert(addr != NetworkAddress.init);
	}
	body {
		m_peer = addr;
	}

	/// (Blocking) Resolves the specified host and resets the peer to this address.
	/// Use AsyncDNS for a non-blocking resolver. (only usable before connecting).
	typeof(this) host(string hostname, size_t port)
	in {
		assert(!isConnected, "Cannot change remote address on a connected socket");
	}
	body {
		m_peer = m_evLoop.resolveHost(hostname, cast(ushort) port);
		return this;
	}

	/// Sets the peer to the specified IP address and port. (only usable before connecting).
	typeof(this) ip(string ip, size_t port)
	in {
		assert(!isConnected, "Cannot change remote address on a connected socket");
	}
	body {
		m_peer = m_evLoop.resolveIP(ip, cast(ushort) port);
		return this;
	}

	/// Starts the connection by registering the associated callback handler in the
	/// underlying OS event loop.
	bool run(void delegate(TCPEvent) del) {
		TCPEventHandler handler;
		handler.del = del;
		handler.conn = this;
		return run(handler);
	}

	///
	bool run(TCPEventHandler del)
	in { assert(!isConnected); }
	body {
		m_socket = m_evLoop.run(this, del);
		if (m_socket == 0)
			return false;
		else
			return true;
	}

	/// Receive data from the underlying stream. To be used when TCPEvent.READ is received by the
	/// callback handler. IMPORTANT: This must be called until is returns a lower value than the buffer!
	final pragma(inline, true)
	uint recv(ref ubyte[] ub)
	//in { assert(isConnected, "No socket to operate on"); }
	//body
	{
		return m_evLoop.recv(m_socket, ub);
	}

	/// Send data through the underlying stream by moving it into the OS buffer.
	final pragma(inline, true)
	uint send(in ubyte[] ub)
	//in { assert(isConnected, "No socket to operate on"); }
	//body
	{
		uint ret = m_evLoop.send(m_socket, ub);
		version(Posix)
			if (m_evLoop.status.code == Status.ASYNC)
				this.writeBlocked = true;
		return ret;
	}

	/// Removes the connection from the event loop, closing it if necessary, and
	/// cleans up the underlying resources.
	bool kill(bool forced = false)
	in { assert(isConnected); }
	body {
		bool ret = m_evLoop.kill(this, forced);
		scope(exit) m_socket = 0;
		return ret;
	}

	@property fd_t socket() const {
		return m_socket;
	}

package:
	mixin COSocketMixins;

	@property void inbound(bool b) {
		m_inbound = b;
	}

	@property bool noDelay() const
	{
		return m_noDelay;
	}

	@property void socket(fd_t sock) {
		m_socket = sock;
	}

	@property fd_t preInitializedSocket() const {
		return m_preInitializedSocket;
	}
}

/// Accepts connections on a single IP:PORT tuple by sending a new inbound AsyncTCPConnection
/// object to the handler for every newly completed handshake.
///
/// Note: If multiple threads are listening to the same IP:PORT tuple, the connections will
/// be distributed evenly between them. However, this behavior on Windows is not implemented yet.
final class AsyncTCPListener
{
private:
nothrow:
	EventLoop m_evLoop;
	fd_t m_socket;
	NetworkAddress m_local;
	bool m_noDelay;
	bool m_started;

public:

	///
	this(EventLoop evl, fd_t sock = fd_t.init) { m_evLoop = evl; m_socket = sock; }

	mixin DefStatus;

	/// Sets the default value for nagle's algorithm on new connections.
	@property void noDelay(bool b)
	in { assert(!m_started, "Cannot set noDelay on a running object."); }
	body {
		m_noDelay = b;
	}

	/// Returns the local internet address as an OS-specific structure.
	@property NetworkAddress local() const
	{
		return m_local;
	}

	/// Sets the local internet address as an OS-specific structure.
	@property void local(NetworkAddress addr)
	in { assert(!m_started, "Cannot rebind a listening socket"); }
	body {
		m_local = addr;
	}

	/// Sets the local listening interface to the specified hostname/port.
	typeof(this) host(string hostname, size_t port)
	in { assert(!m_started, "Cannot rebind a listening socket"); }
	body {
		m_local = m_evLoop.resolveHost(hostname, cast(ushort) port);
		return this;
	}

	/// Sets the local listening interface to the specified ip/port.
	typeof(this) ip(string ip, size_t port)
	in { assert(!m_started, "Cannot rebind a listening socket"); }
	body {
		m_local = m_evLoop.resolveIP(ip, cast(ushort) port);
		return this;
	}

	/// Starts accepting connections by registering the given handler with the underlying OS event.
	bool run(void delegate(TCPEvent) delegate(AsyncTCPConnection) del) {
		TCPAcceptHandler handler;
		handler.ctxt = this;
		handler.del = del;
		return run(handler);
	}

	private bool run(TCPAcceptHandler del)
	in {
		assert(m_local != NetworkAddress.init, "Cannot bind without an address. Please run .host() or .ip()");
	}
	body {
		m_socket = m_evLoop.run(this, del);
		if (m_socket == fd_t.init)
			return false;
		else {
			if (m_local.port == 0)
				m_local = m_evLoop.localAddr(m_socket, m_local.ipv6);
			m_started = true;
			return true;
		}
	}

	/// Use to implement distributed servicing of connections
	@property fd_t socket() const {
		return m_socket;
	}

	/// Stops accepting connections and cleans up the underlying OS resources.
	bool kill()
	in { assert(m_socket != 0); }
	body {
		bool ret = m_evLoop.kill(this);
		if (ret)
			m_started = false;
		return ret;
	}

package:
	version(Posix) mixin EvInfoMixins;
	version(Distributed) version(Windows) mixin TCPListenerDistMixins;
	@property bool noDelay() const
	{
		return m_noDelay;
	}
}

package struct TCPEventHandler {
	AsyncTCPConnection conn;

	/// Use getContext/setContext to persist the context in each activity. Using AsyncTCPConnection in args
	/// allows the EventLoop implementation to create and pass a new object, which is necessary for listeners.
	void delegate(TCPEvent) del;

	void opCall(TCPEvent ev){
		if (conn is null || !conn.isConnected) return; //, "Connection was disposed before shutdown could be completed");
		del(ev);
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

///
enum TCPEvent : char {
	ERROR = 0, /// The connection will be forcefully closed, this is debugging information
	CONNECT, /// indicates write will not block, although recv may or may not have data
	READ, /// called once when new bytes are in the buffer
	WRITE, /// only called when send returned Status.ASYNC
	CLOSE /// The connection is being shutdown
}

///
enum TCPOption : char {
	NODELAY = 0,		/// Don't delay send to coalesce packets
	REUSEADDR = 1, ///
	REUSEPORT, ///
	CORK, ///
	LINGER, ///
	BUFFER_RECV, ///
	BUFFER_SEND, ///
	TIMEOUT_RECV, ///
	TIMEOUT_SEND, ///
	TIMEOUT_HALFOPEN, ///
	KEEPALIVE_ENABLE, ///
	KEEPALIVE_DEFER,	/// Start keeplives after this period
	KEEPALIVE_COUNT,	/// Number of keepalives before death
	KEEPALIVE_INTERVAL,	/// Interval between keepalives
	DEFER_ACCEPT, ///
	QUICK_ACK,			/// Bock/reenable quick ACKs.
	CONGESTION ///
}
