module event.udp;

import event.types;

import event.events;

final nothrow class AsyncUDPSocket
{
nothrow:
private:
	EventLoop m_evLoop;
	fd_t m_socket;
	NetworkAddress m_local;

public:
	this(EventLoop evl)
	in { assert(evl !is null); }
	body { m_evLoop = evl; }

	mixin DefStatus;

	bool broadcast(bool b) 
	in { assert(m_socket == fd_t.init, "Cannot change state on unbound UDP socket"); }	
	body {
		return m_evLoop.broadcast(m_socket, b);
	}

	uint recvFrom(ref ubyte[] data, ref NetworkAddress addr) {
		return m_evLoop.recvFrom(m_socket, data, addr);
	}
	
	uint sendTo(in ubyte[] data, in NetworkAddress addr) {
		return m_evLoop.sendTo(m_socket, data, addr);
	}

	typeof(this) host(string hostname, size_t port)
	in { assert(m_socket == fd_t.init, "Cannot rebind an UDP socket"); }
	body
	{
		m_local = m_evLoop.resolveHost(hostname, cast(ushort) port);
		return this;
	}

	typeof(this) ip(string ip, size_t port)
	in { assert(m_socket == fd_t.init, "Cannot rebind an UDP socket"); }
	body {
		m_local = m_evLoop.resolveIP(ip, cast(ushort) port);
		return this;
	}

	bool run(void delegate(UDPEvent) del) 
	{
		UDPHandler handler;
		handler.del = del;
		handler.conn = this;
		return run(handler);
	}

	private bool run(UDPHandler del)
	in { assert(m_local != NetworkAddress.init) && m_socket == fd_t.init, "Cannot rebind an UDP socket"); }
	body {
		m_socket = m_evLoop.run(this, del);
		if (m_socket == fd_t.init)
			return false;
		else
			return true;
	}
	
	bool kill()
	in { assert(m_socket != fd_t.init); }
	body {
		return m_evLoop.kill(this);
	}

	@property NetworkAddress local() const
	{
		return m_local;
	}

package:
	version(Posix) mixin EvInfoMixins;

	@property fd_t socket() const {
		return m_socket;
	}

	@property void socket(fd_t val) {
		m_socket = val;
	}

}

package struct UDPHandler {
	AsyncUDPSocket conn;
	void delegate(UDPEvent) fct;
	void opCall(UDPEvent code){
		assert(conn !is null);
		del(code);
		assert(conn !is null);
		return;
	}
}

enum UDPEvent : char {
	ERROR = 0,
	READ, 
	WRITE
}