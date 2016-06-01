module libasync.uds;

version (Posix):

public import std.socket : UnixAddress;

import libasync.types;
import libasync.events;
import libasync.event;

import core.sys.posix.sys.socket;

final class AsyncUDSConnection
{
package:
    EventLoop m_evLoop;

private:
    UnixAddress m_peer;
    AsyncEvent m_event;

nothrow:
    fd_t m_socket, m_preInitializedSocket;

public:
    this(EventLoop evl)
    in { assert(evl !is null); }
    body {
        m_evLoop = evl;
    }

    mixin DefStatus;

    // Returns false if the connection has gone.
    @property bool isConnected() const {
        return m_socket != fd_t.init;
    }

    @property UnixAddress peer() const
    {
        return cast(UnixAddress) m_peer;
    }

    @property void peer(UnixAddress addr)
    in {
        assert(!isConnected, "Cannot change remote address on a connected socket");
        assert(addr !is UnixAddress.init);
    }
    body {
        m_peer = addr;
    }

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
		return m_evLoop.kill(m_event, forced);
	}

    @property fd_t socket() const {
		return m_socket;
	}

package:
    @property void socket(fd_t sock) {
        m_socket = sock;
    }

    @property fd_t preInitializedSocket() const {
        return m_preInitializedSocket;
    }
}
