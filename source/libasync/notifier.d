///
module libasync.notifier;

import libasync.types;
import libasync.events;

/// Thread-local event dispatcher/handler, used to wake up the associated
/// callback in a new call stack originating from the event loop.
final class AsyncNotifier
{
	///
	void delegate() m_evh;
nothrow:
private:
	EventLoop m_evLoop;
	fd_t m_evId;
	version(Posix) static if (EPOLL) shared ushort m_owner;

public:
	///
	this(EventLoop evl)
	in {
		assert(evl !is null);
	}
	body {
		m_evLoop = evl;
	}

	mixin DefStatus;

	/// Starts the notifier with the associated delegate (handler)
	bool run(void delegate() del) {
		m_evh = cast(void delegate()) del;
		m_evId = m_evLoop.run(this);
		if (m_evId != fd_t.init)
			return true;
		else
			return false;
	}

	/// Cleans up associated resources.
	bool kill()
	{
		return m_evLoop.kill(this);
	}

	/// Enqueues a call to the handler originating from the thread-local event loop.
	bool trigger()
	{
		return m_evLoop.notify(m_evId, this);
	}

	///
	@property fd_t id() const {
		return m_evId;
	}

package:
	version(Posix) mixin EvInfoMixins;

	void handler() {
		try m_evh();
		catch (Exception) {}
		return;
	}
}

package struct NotifierHandler {
	AsyncNotifier ctxt;
	void function(AsyncNotifier) fct;

	void opCall() {
		assert(ctxt !is null);
		fct(ctxt);
		return;
	}
}
