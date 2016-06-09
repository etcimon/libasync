///
module libasync.timer;

import libasync.types;
import libasync.events;
import std.datetime;

///
final class AsyncTimer
{

nothrow:
private:
	bool m_oneshot = true;
	fd_t m_timerId;
	EventLoop m_evLoop;
	TimerHandler m_evh;
	Duration m_timeout;
	bool m_shooting = false;
	bool m_rearmed = false;

public:
	///
	this(EventLoop evl)
	in { assert(evl !is null); }
	body { m_evLoop = evl; }

	mixin DefStatus;

	/// Returns the Duration that the timer will wait before calling the handler
	/// after it is run.
	@property Duration timeout() const {
		return m_timeout;
	}

	/// Returns whether the timer is set to rearm itself (oneShot=false) or
	/// if it will have to be rearmed (oneShot=true).
	@property bool oneShot() const {
		return m_oneshot;
	}

	/// Sets the timer to become periodic. For a running timer,
	/// this setting will take effect after the timer is expired (oneShot) or
	/// after it is killed (periodic).
	typeof(this) periodic(bool b = true)
	in { assert(m_timerId == 0 || m_oneshot); }
	body
	{
		m_oneshot = !b;
		return this;
	}

	/// Sets or changes the duration on the timer. For a running timer,
	/// this setting will take effect after the timer is expired (oneShot) or
	/// after it is killed (periodic).
	typeof(this) duration(Duration dur) {
		m_timeout = dur;
		return this;
	}

	/// Runs a non-periodic, oneshot timer once using the specified Duration as
	/// a timeout. The handler from the last call to run() will be reused.
	bool rearm(Duration dur)
	in {
		assert(m_timeout > 0.seconds);
		// assert(m_shooting);
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

	/// Starts the timer using the delegate as an expiration callback.
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

	/// Cleans up underlying OS resources. This is required to change the
	/// timer from periodic to oneshot, or before disposing of this object.
	bool kill() {
		return m_evLoop.kill(this);
	}

	///
	@property fd_t id() {
		return m_timerId;
	}

package:
	version(Posix) mixin EvInfoMixins;

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
