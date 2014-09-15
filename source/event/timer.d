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
	TimerHandler m_evh;
	Duration m_timeout;
	bool m_rearmed = false;

public:
	this(EventLoop evl)
	in { assert(evl !is null); }
	body { m_evLoop = evl; }

	mixin DefStatus;

	@property Duration timeout() const {
		return m_timeout;
	}

	@property void oneShot(bool b) {
		m_oneshot = b;
	}

	// Changing the duration on a running timer takes effet on the next run.
	typeof(this) duration(Duration dur) {
		m_timeout = dur;
		return this;
	}

	bool rearm(Duration dur)
	in { 
		assert(m_timeout > 0.seconds);
		assert(m_oneshot, "Cannot rearm a periodic timer, it must fist be killed.");
	}
	body {
		m_rearmed = true;

		m_timerId = m_evLoop.run(this, m_evh, dur);
		m_timeout = dur;

		if (m_timerId == 0)
			return false;
		else
			return true;
	}

	bool run(void delegate() del) 
	in { 
		assert(m_timeout > 0.seconds);
		assert(m_oneshot || !m_timerId, "Cannot rearm a periodic timer, it must fist be killed.");
	}
	body {
		TimerHandler handler;
		handler.del = del;
		handler.ctxt = this;

		return run(handler);
	}

	private bool run(TimerHandler cb) {
		m_evh = cb;

		if (m_timerId)
			m_rearmed = true;
		else
			m_rearmed = false;
		m_timerId = m_evLoop.run(this, cb, m_timeout);
		// try writeln("Timer starting", m_timerId); catch {}
		if (m_timerId == 0)
			return false;
		else
			return true;
	}
	
	bool kill() {
		return m_evLoop.kill(this);
	}

package:

	version(Posix) mixin EvInfoMixins;

	@property bool oneShot() const {
		return m_oneshot;
	}
	
	@property fd_t id() {
		return m_timerId;
	}
	
	@property void id(fd_t fd) {
		m_timerId = fd;
	}

	@property void rearmed(bool b) {
		m_rearmed = b;
	}

	@property bool rearmed() {
		return m_rearmed;
	}

	/*void handler() {
		try m_evh();
		catch {}
		return;
	}*/
}

package struct TimerHandler {
	AsyncTimer ctxt;
	void delegate() del;
	void opCall() {
		assert(ctxt !is null);
		ctxt.m_rearmed = false;
		del();
		return;
	}
}