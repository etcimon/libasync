module event.watcher;
version(none):
import event.types;

import event.events;

final nothrow class AsyncDirectoryWatcher
{
nothrow:
private:
	EventLoop m_evLoop;
	fd_t m_socket;
	NetworkAddress m_local;
	void* m_ctxt;
	
public:
	this(EventLoop evl)
	in { assert(evl !is null); }
	body { m_evLoop = evl; }
	
	mixin DefStatus;
	
	mixin ContextMgr;
	
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
	
	@property void host(string hostname, size_t port)
	in { assert(m_socket == fd_t.init, "Cannot rebind an UDP socket"); }
	body
	{
		m_local = m_evLoop.resolveHost(hostname, cast(ushort) port);
	}
	
	@property void ip(string ip, size_t port)
	in { assert(m_socket == fd_t.init, "Cannot rebind an UDP socket"); }
	body {
		m_local = m_evLoop.resolveIP(ip, cast(ushort) port);
	}
	
	bool run(UDPHandler del, NetworkAddress addr)
	in { assert(m_socket == fd_t.init, "Cannot rebind an UDP socket"); }
	body {
		m_local = addr;
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

struct UDPHandler {
	AsyncUDPSocket conn;
	void function(AsyncUDPSocket, UDPEvent) fct;
	void opCall(UDPEvent code){
		assert(conn !is null);
		fct(conn, code);
		assert(conn !is null);
		return;
	}
}

enum UDPEvent : char {
	ERROR = 0,
	READ, 
	WRITE
}