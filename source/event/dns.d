module event.dns;

import event.types;
import event.events;
import core.thread : Thread, ThreadGroup;
import core.sync.mutex;
import core.sync.condition;
import core.atomic;
import event.threads;

enum DNSCmd {
	RESOLVEHOST,
	RESOLVEIP
}

/// Resolves internet addresses and returns the results in a specified callback.
shared final class AsyncDNS
{
nothrow:
private:
	EventLoop m_evLoop;
	bool m_busy;
	bool m_error;
	DNSReadyHandler m_handler;
	DNSCmdInfo m_cmdInfo;
	StatusInfo m_status;
	Thread m_owner;
	
public:
	this(EventLoop evl) {
		m_evLoop = cast(shared) evl;
		try m_cmdInfo.ready = new shared AsyncSignal(cast(EventLoop)m_evLoop); catch { assert(false, "Failed to start DNS Signaling"); }
		m_cmdInfo.ready.run(cast(void delegate())&callback);
		m_owner = cast(shared)Thread.getThis();
		try m_cmdInfo.mtx = cast(shared) new Mutex; catch {}
	}
	
	synchronized @property StatusInfo status() const
	{
		return cast(StatusInfo) m_status;
	}
	
	@property string error() const
	{
		return status.text;
	}

	/// Uses the callback for all resolved addresses.
	shared(typeof(this)) handler(void delegate(NetworkAddress) del) {
		shared DNSReadyHandler handler;
		handler.del = cast(shared) del;
		handler.ctxt = this;
		try synchronized(this) m_handler = handler; catch { assert(false, "Failed to set handler in AsyncDNS"); }
		return this;
	}

	/// Sends a request through a thread pool for the specified host to be resolved. The
	/// callback specified in run() will be signaled with the OS-specific NetworkAddress
	/// structure.
	bool resolveHost(string url, bool ipv6 = false)
	in {
		assert(!m_busy, "Resolver is busy or closed");
		assert(m_handler.ctxt !is null, "AsyncDNS must be running before being operated on.");
	}
	body {
		try synchronized(m_cmdInfo.mtx) { 
			m_cmdInfo.command = DNSCmd.RESOLVEHOST;
			m_cmdInfo.ipv6 = ipv6;
			m_cmdInfo.url = cast(shared) url;
		} catch {}
		
		return sendCommand();
	}

	/// Returns an OS-specific NetworkAddress structure from the specified IP.
	NetworkAddress resolveIP(string url, bool ipv6)
	in {
		assert(!m_busy, "Resolver is busy or closed");
		assert(m_handler.ctxt !is null, "AsyncDNS must be running before being operated on.");
	}
	body {
		return (cast(EventLoop)m_evLoop).resolveIP(url, 0, ipv6?isIPv6.yes:isIPv6.no);
	}

	// chooses a thread or starts it if necessary
	private bool sendCommand() 
	in { assert(!waiting, "File is busy or closed"); }
	body {
		waiting = true;
		m_error = false;
		status = StatusInfo.init;
		
		Waiter cmd_handler;
		try {
			cmd_handler = popWaiter();		
		} catch (Throwable e) {
			import std.stdio;
			try {
				status = StatusInfo(Status.ERROR, e.toString());
				m_error = true;
			} catch {}
			
			return false;
			
		}
		assert(cmd_handler.cond);
		m_cmdInfo.waiter = cast(shared)cmd_handler;
		try {
			synchronized(gs_wlock) 
				gs_jobs.insert(CommandInfo(CmdInfoType.DNS, cast(void*) this));

			cmd_handler.cond.notifyAll(); 
		}
		catch (Exception e){
			import std.stdio;
			try writeln("Exception occured notifying foreign thread: ", e); catch {}
		}
		return true;
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
		catch {}
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
	
	void callback() {

		try {
			m_handler(cast(NetworkAddress)m_cmdInfo.addr);
		}
		catch (Throwable e) {
			import std.stdio : writeln;
			try writeln("Failed to send command. ", e.toString()); catch {}
		}
	}

}

package shared struct DNSCmdInfo
{
	DNSCmd command;
	bool ipv6;
	string url;
	NetworkAddress addr;
	Waiter waiter;
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
