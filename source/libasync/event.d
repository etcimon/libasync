///
module libasync.event;

import core.thread;
import libasync.types;
import libasync.events;

/// Takes a raw kernel-emitted file descriptor and registers its events into the event loop for async processing
/// NOTE: If it's a socket, it must be made non-blocking before being passed here.
/// NOTE: By default dispatched events are READ, WRITE, and ERROR; enabling 'stateful' adds CONNECT and CLOSE
class AsyncEvent
{
nothrow:
private:
	Thread m_owner;
	EventLoop m_evLoop;
	fd_t m_evId;
	bool m_stateful;

public:
	///
	this(EventLoop evl, fd_t ev_id, bool stateful = false)
	in {
		assert(evl !is null && ev_id > 0);
	}
	body {
		m_evLoop = evl;
		import core.thread : Thread;
		m_owner = Thread.getThis();
		m_evId = ev_id;
		m_stateful = stateful;
	}

	///
	@property bool hasError() const
	{
		return (cast(EventLoop)m_evLoop).status.code != Status.OK;
	}

	/// Used to diagnose errors when run() or kill() returns false
	@property StatusInfo status() const {
		return (cast(EventLoop)m_evLoop).status;
	}

	/// Human-readable string describing the error
	@property string error() const {
		return (cast(EventLoop)m_evLoop).error;
	}

	/// Registers the signal handler in the event loop
	bool run(void delegate(EventCode) del)
	in {
		debug assert(Thread.getThis() is cast(Thread)m_owner);
	}
	body {

		EventHandler handler;
		handler.del = del;
		handler.ev = this;
		return (cast(EventLoop) m_evLoop).run(this, handler);
	}

	/// Returns the Thread that created this object.
	synchronized @property Thread owner() const {
		return cast(Thread) m_owner;
	}

	///
	@property fd_t id() const {
		return m_evId;
	}

	/// Removes the event from the event loop, closing the file descriptor if necessary,
	/// and cleans up the underlying resources.
	bool kill(bool forced = false)
	body {
		scope(exit) m_evId = 0;
		return m_evLoop.kill(this, forced);
	}

package:
	mixin COSocketMixins;

	@property bool stateful() const {
		return m_stateful;
	}

	@property void stateful(bool stateful) {
		m_stateful = stateful;
	}

	@property void id(fd_t id) {
		m_evId = id;
	}
}

package struct EventHandler {
	AsyncEvent ev;
	void delegate(EventCode) del;
	void opCall(EventCode code){
		assert(ev !is null);
		del(code);
		assert(ev !is null);
		return;
	}
}

///
enum EventCode : char {
	///
	ERROR = 0,
	///
	READ,
	///
	WRITE,
	///
	CONNECT,
	///
	CLOSE
}
