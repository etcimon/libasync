﻿///
module libasync.dns;

import libasync.types;
import libasync.events;
import core.thread : Thread, ThreadGroup;
import core.sync.mutex;
import core.sync.condition;
import core.atomic;
import libasync.threads;
import libasync.internals.freelist;
import libasync.internals.queue;
import libasync.internals.logging;

///
enum DNSCmd {
	///
	RESOLVEHOST,
	///
	RESOLVEIP
}

/// Resolves internet addresses and returns the results in a specified callback.
shared final class AsyncDNS
{
nothrow:
	package EventLoop m_evLoop;
private:
	bool m_busy;
	bool m_error;
	DNSReadyHandler m_handler;
	DNSCmdInfo m_cmdInfo;
	StatusInfo m_status;
	Thread m_owner;
	static if (is_Windows || EPOLL) {
		AsyncDNSRequest* m_activeReq;
	}
public:
	///
	this(EventLoop evl) {
		m_evLoop = cast(shared) evl;
		try {
			m_cmdInfo.ready = new shared AsyncSignal(cast(EventLoop)m_evLoop);
		} catch (Throwable) {
			assert(false, "Failed to start DNS Signaling");
		}
		m_cmdInfo.ready.run(cast(void delegate())&callback);

		m_owner = cast(shared)Thread.getThis();
		try m_cmdInfo.mtx = cast(shared) new Mutex; catch (Exception) {}
	}

	///
	synchronized @property StatusInfo status() const
	{
		return cast(StatusInfo) m_status;
	}

	///
	@property string error() const
	{
		return status.text;
	}

	/// Uses the callback for all resolved addresses.
	shared(typeof(this)) handler(void delegate(NetworkAddress) del) {
		shared DNSReadyHandler handler;
		handler.del = cast(shared) del;
		handler.ctxt = this;
		try synchronized(this) m_handler = handler;
		catch (Throwable) assert(false, "Failed to set handler in AsyncDNS");
		return this;
	}

	/// Sends a request through a thread pool for the specified host to be resolved. The
	/// callback specified in run() will be signaled with the OS-specific NetworkAddress
	/// structure.
	bool resolveHost(string url, bool ipv6 = false, bool force_async = false)
	in {
		assert(!m_busy, "Resolver is busy or closed");
		assert(m_handler.ctxt !is null, "AsyncDNS must be running before being operated on.");
	}
	do {
		static if (LOG) .tracef("Resolving url: %s", url);	
		static if (is_Windows || EPOLL) {
			if (force_async) {
				tracef("Resolving async with signal fd: %X", m_cmdInfo.ready.id);
				m_cmdInfo.command = DNSCmd.RESOLVEHOST;
				m_cmdInfo.ipv6 = ipv6;
				m_cmdInfo.url = cast(shared) url;
				AsyncDNSRequest* dns_req = AsyncDNSRequest.alloc(this);
				m_activeReq = cast(shared)dns_req;
				return (cast(EventLoop)m_evLoop).resolve(dns_req, cmdInfo.url, 0, cmdInfo.ipv6?isIPv6.yes:isIPv6.no);
			}
		}

		version(Libasync_Threading)
			if (force_async == true) {
				synchronized(m_cmdInfo.mtx) {
					m_cmdInfo.command = DNSCmd.RESOLVEHOST;
					m_cmdInfo.ipv6 = ipv6;
					m_cmdInfo.url = cast(shared) url;
				}
				return doOffThread({ process(this); });
			} 
			
		{
			m_cmdInfo.command = DNSCmd.RESOLVEHOST;
			m_cmdInfo.ipv6 = ipv6;
			m_cmdInfo.url = cast(shared) url;
			m_cmdInfo.addr = cast(shared)( (cast(EventLoop)m_evLoop).resolveHost(cmdInfo.url, 0, cmdInfo.ipv6?isIPv6.yes:isIPv6.no) );
			callback();
			return true;
		}

	}

	/// Returns an OS-specific NetworkAddress structure from the specified IP.
	NetworkAddress resolveIP(string url, bool ipv6)
	in {
		assert(!m_busy, "Resolver is busy or closed");
		assert(m_handler.ctxt !is null, "AsyncDNS must be running before being operated on.");
	}
	do {
		return (cast(EventLoop)m_evLoop).resolveIP(url, 0, ipv6?isIPv6.yes:isIPv6.no);
	}

	/// Cleans up underlying resources. Used as a placeholder for possible future purposes.
	bool kill() {
		return true;
	}

package:
	synchronized @property DNSCmdInfo cmdInfo() {
		return m_cmdInfo;
	}

	shared(NetworkAddress*) addr() {
		try synchronized(m_cmdInfo.mtx)
			return cast(shared)&m_cmdInfo.addr;
		catch (Exception) {}
		return null;
	}

	synchronized @property void status(StatusInfo stat) {
		m_status = cast(shared) stat;
	}

	synchronized @property bool waiting() const {
		return cast(bool) m_busy;
	}

	synchronized @property void waiting(bool b) {
		m_busy = cast(shared) b;
	}

	synchronized void callback() {
		static if (is_Windows || EPOLL) {
			if (m_activeReq) {
				import std.exception : assumeWontThrow;
				assumeWontThrow(AsyncDNSRequest.free(cast(AsyncDNSRequest*)m_activeReq));
				m_activeReq = null;
			} 
		}
		try {
			m_handler(cast(NetworkAddress)m_cmdInfo.addr);
		}
		catch (Throwable e) {
			warningf("Failed to send command. %s", e.toString());
		}
	}

}

package struct AsyncDNSRequest
{
	AsyncDNS dns;      /// DNS resolver to use
	version(Windows) {
		import libasync.internals.win32;
		PADDRINFOEX infos;
		AsyncOverlapped* overlapped;
		~this() {
			try {
				AsyncOverlapped.free(overlapped);
			} catch (Exception e) {
				import libasync.internals.logging;
				static if (LOG) tracef("Exception freeing in AsyncDNSRequest: %s", e.toString());
			}
		}
	}
	static if (EPOLL) {
		import libasync.internals.socket_compat : gaicb, sigevent, addrinfo;
		gaicb* host;
		sigevent sig;
		~this() {
			static if (LOG) tracef("Destroying AsyncDNSRequest");
			try {
				ThreadMem.free(cast(addrinfo*)host.ar_request);
				ThreadMem.free(cast(gaicb*)host);
			} catch (Exception e) {
				import libasync.internals.logging;
				static if (LOG) tracef("Exception freeing in AsyncDNSRequest: %s", e.toString());
			}
		}
	}
	mixin FreeList!1_000;	
}



package shared struct DNSCmdInfo
{
	DNSCmd command;
	bool ipv6;
	string url;
	NetworkAddress addr;
	AsyncSignal ready;
	AsyncDNS dns;
	Mutex mtx; // for NetworkAddress writing
}

package shared struct DNSReadyHandler {
	AsyncDNS ctxt;
	void delegate(NetworkAddress) del;

	void opCall(NetworkAddress addr) {
		assert(ctxt !is null);
		del(addr);
		return;
	}
}

private void process(shared AsyncDNS ctxt) {
	auto evLoop = getThreadEventLoop();

	DNSCmdInfo cmdInfo = ctxt.cmdInfo();
	auto mutex = cmdInfo.mtx;
	DNSCmd cmd;
	string url;
	cmd = cmdInfo.command;
	url = cmdInfo.url;

	try final switch (cmd)
	{
		case DNSCmd.RESOLVEHOST:
			*ctxt.addr = cast(shared) evLoop.resolveHost(url, 0, cmdInfo.ipv6 ? isIPv6.yes : isIPv6.no);
			break;

		case DNSCmd.RESOLVEIP:
			*ctxt.addr = cast(shared) evLoop.resolveIP(url, 0, cmdInfo.ipv6 ? isIPv6.yes : isIPv6.no);
			break;

	} catch (Throwable e) {
		auto status = StatusInfo.init;
		status.code = Status.ERROR;
		try status.text = e.toString(); catch (Throwable) {}
		ctxt.status = status;
	}

	try cmdInfo.ready.trigger(evLoop);
	catch (Throwable e) {
		auto status = StatusInfo.init;
		status.code = Status.ERROR;
		try status.text = e.toString(); catch (Throwable) {}
		ctxt.status = status;
	}
}
