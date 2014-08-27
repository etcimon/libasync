module event.timer;

import event.types;
import event.events;
import std.datetime;

final class AsyncTimer
{

nothrow:
private:
	bool m_oneshot = true;
	fd_t m_timerId;
	EventLoop m_evLoop;
	void* m_ctxt;
	TimerHandler m_evh;

public:
	this(EventLoop evl)
	in { assert(evl !is null); }
	body { m_evLoop = evl; }

	mixin ContextMgr;

	@property oneShot(bool b) {
		m_oneshot = b;
	}

	bool run(TimerHandler cb, Duration timeout) {
		m_evh = cb;
		m_timerId = m_evLoop.run(this, cb, timeout);
		if (m_timerId == 0)
			return false;
		else
			return true;
	}
	
	bool kill() {
		return m_evLoop.kill(this);
	}

package:

	version(Posix) static if (!EPOLL) mixin EvInfoMixins;

	@property bool oneShot() const {
		return m_oneshot;
	}

	@property fd_t id() {
		return m_timerId;
	}

	void handler() {
		try m_evh();
		catch {}
		return;
	}
}

struct TimerHandler {
	AsyncTimer ctxt;
	void function(AsyncTimer ctxt) fct;
	void opCall() {
		assert(ctxt !is null);
		fct(ctxt);
		return;
	}
}