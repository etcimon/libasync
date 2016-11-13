///
module libasync.uds;

version (Posix):

public import std.socket : UnixAddress;

import libasync.types;
import libasync.events;
import libasync.event;

import core.sys.posix.sys.socket;

///
final class AsyncUDSConnection
{
package:
	EventLoop m_evLoop;
	AsyncEvent m_event;

private:
	UnixAddress m_peer;
	fd_t m_socket, m_preInitializedSocket;
	bool m_inbound;

nothrow:

package:
	@property fd_t socket() const {
		return m_socket;
	}

	@property fd_t preInitializedSocket() const {
		return m_preInitializedSocket;
	}

	@property void inbound(bool inbound) {
		m_inbound = inbound;
	}

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

	/// Returns true if this connection was accepted by an AsyncUDSListener instance.
	@property bool inbound() const {
		return m_inbound;
	}

	///
	@property UnixAddress peer() const
	{
		return cast(UnixAddress) m_peer;
	}

	///
	@property void peer(UnixAddress addr)
	in {
		assert(!isConnected, "Cannot change remote address on a connected socket");
		assert(addr !is UnixAddress.init);
	}
	body {
		m_peer = addr;
	}

	///
	bool run(void delegate(EventCode) del)
	in { assert(!isConnected); }
	body {
		m_socket = m_evLoop.run(this);
		if (m_socket == 0) return false;

		m_event = new AsyncEvent(m_evLoop, m_socket, true);
		return m_event.run(del);
	}

	/// Receive data from the underlying stream. To be used when EventCode.READ is received by the
	/// callback handler. IMPORTANT: This must be called until is returns a lower value than the buffer!
	final pragma(inline, true)
	uint recv(ref ubyte[] ub)
	{
		return m_evLoop.recv(m_socket, ub);
	}

	/// Send data through the underlying stream by moving it into the OS buffer.
	final pragma(inline, true)
	uint send(in ubyte[] ub)
	{
		uint ret = m_evLoop.send(m_socket, ub);
		if (m_evLoop.status.code == Status.ASYNC)
			m_event.writeBlocked = true;
		return ret;
	}

	/// Removes the connection from the event loop, closing it if necessary, and
	/// cleans up the underlying resources.
	bool kill(bool forced = false)
	in { assert(isConnected); }
	body {
		scope(exit) m_socket = 0;
		return m_event.kill(forced);
	}
}

///
final class AsyncUDSListener
{
package:
	EventLoop m_evLoop;

private:
	AsyncEvent m_event;

	UnixAddress m_local;
	fd_t m_socket;
	bool m_started, m_unlinkFirst;
	void delegate(EventCode) delegate(AsyncUDSConnection) nothrow m_del;

nothrow:

private:
	void handler(EventCode code)
	{
		switch (code) {
			case EventCode.READ:
				AsyncUDSConnection conn = void;
				while ((conn = m_evLoop.accept(this)) !is null) {
					conn.run(m_del(conn));
				}
				break;
			default:
				break;
		}
	}

package:
	@property bool unlinkFirst() const {
		return m_unlinkFirst;
	}

	@property fd_t socket() const {
		return m_socket;
	}

public:
	///
	this(EventLoop evl, bool unlinkFirst = true)
	in { assert(evl !is null); }
	body {
		m_evLoop = evl;
		m_unlinkFirst = unlinkFirst;
	}

	mixin DefStatus;

	/// Returns the unix domain socket address as an OS-specific structure.
	@property UnixAddress local() const
	{
		return cast(UnixAddress) m_local;
	}

	/// Sets the local internet address as an OS-specific structure.
	@property void local(UnixAddress addr)
	in { assert(!m_started, "Cannot rebind a listening socket"); }
	body {
		m_local = addr;
	}

	/// Starts accepting connections by registering the given handler with the underlying OS event.
	bool run(void delegate(EventCode) delegate(AsyncUDSConnection) nothrow del)
	in {
		assert(m_local !is UnixAddress.init, "Cannot bind without an address. Please set .local");
	}
	body {
		m_del = del;
		m_socket = m_evLoop.run(this);
		if (m_socket == 0) return false;

		m_event = new AsyncEvent(m_evLoop, m_socket, false);
		m_started = m_event.run(&handler);
		return m_started;
	}

	/// Stops accepting connections and cleans up the underlying OS resources.
	/// NOTE: MUST be called to clean up the domain socket path
	bool kill()
	in { assert(m_socket != 0); }
	body {
		import core.sys.posix.unistd : unlink;
		import core.sys.posix.sys.un : sockaddr_un;

		bool ret = m_evLoop.kill(m_event);
		if (ret) m_started = false;
		unlink(cast(char*) (cast(sockaddr_un*) m_local.name).sun_path);
		return ret;
	}
}
