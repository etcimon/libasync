///
module libasync.udp;

import libasync.types;

import libasync.events;

/// Wrapper for a UDP Stream which must be bound to a socket.
final nothrow class AsyncUDPSocket
{
nothrow:
private:
	EventLoop m_evLoop;
	fd_t m_socket;
	fd_t m_preInitializedSocket;
	NetworkAddress m_local;

public:
	///
	this(EventLoop evl, fd_t preInitializedSocket = fd_t.init)
	in { assert(evl !is null); }
	body {
		m_evLoop = evl;
		m_preInitializedSocket = preInitializedSocket;
	}

	mixin DefStatus;


	/// Returns the locally bound address as an OS-specific structure.
	@property NetworkAddress local() const
	{
		return m_local;
	}

	/// Grants broadcast permissions to the socket (must be set before run).
	bool broadcast(bool b)
	in { assert(m_socket != fd_t.init, "Cannot change state on unbound UDP socket"); }
	body {
		return m_evLoop.broadcast(m_socket, b);
	}

	/// Sets the hostname and port to which the UDP socket must be bound locally.
	typeof(this) host(string hostname, size_t port)
	in { assert(m_socket == fd_t.init, "Cannot rebind an UDP socket"); }
	body
	{
		m_local = m_evLoop.resolveHost(hostname, cast(ushort) port);
		return this;
	}

	/// Sets the IP and port to which the UDP socket will be bound locally.
	typeof(this) ip(string ip, size_t port)
	in { assert(m_socket == fd_t.init, "Cannot rebind an UDP socket"); }
	body {
		m_local = m_evLoop.resolveIP(ip, cast(ushort) port);
		return this;
	}

	/// Sets the local network address to which this UDP Socket will be bound.
	@property void local(NetworkAddress l)
	in {
		assert(l != NetworkAddress.init, "The local address is empty");
		assert(m_socket == fd_t.init, "Cannot rebind an UDP socket");
	}
	body {
		m_local = l;
	}

	/// Registers the UDP socket in the underlying OS event loop, forwards
	/// all related events to the specified delegate.
	bool run(void delegate(UDPEvent) del)
	{
		UDPHandler handler;
		handler.del = del;
		handler.conn = this;
		return run(handler);
	}

	private bool run(UDPHandler del)
	in { assert(m_local != NetworkAddress.init && m_socket == fd_t.init, "Cannot rebind an UDP socket"); }
	body {
		m_socket = m_evLoop.run(this, del);
		if (m_socket == fd_t.init)
			return false;
		else {
			if (m_local.port == 0)
				m_local = m_evLoop.localAddr(m_socket, m_local.ipv6);
			return true;
		}
	}

	/// Receives data from one peer and copies its address to the
	/// associated OS-specific address structure.
	uint recvFrom(ref ubyte[] data, ref NetworkAddress addr) {
		return m_evLoop.recvFrom(m_socket, data, addr);
	}

	/// Sends data to the internet address specified by the associated
	/// OS-specific structure.
	uint sendTo(in ubyte[] data, in NetworkAddress addr) {
		return m_evLoop.sendTo(m_socket, data, addr);
	}

	/// Cleans up the resources associated with this object in the underlying OS.
	bool kill()
	in { assert(m_socket != fd_t.init); }
	body {
		return m_evLoop.kill(this);
	}

	@property fd_t socket() const {
		return m_socket;
	}

package:
	version(Posix) mixin EvInfoMixins;

	@property void socket(fd_t val) {
		m_socket = val;
	}

	@property fd_t preInitializedSocket() const {
		return m_preInitializedSocket;
	}
}

package struct UDPHandler {
	AsyncUDPSocket conn;
	void delegate(UDPEvent) del;
	void opCall(UDPEvent code){
		if(conn is null)
			return;
		del(code);
		assert(conn !is null);
		return;
	}
}

///
enum UDPEvent : char {
	ERROR = 0, ///
	READ, ///
	WRITE ///
}
