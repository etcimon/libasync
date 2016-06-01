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
