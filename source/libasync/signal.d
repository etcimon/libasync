///
module libasync.signal;
import std.traits;

import libasync.types;
import libasync.events;
import core.thread;
import core.sync.mutex : Mutex;
import std.exception : assumeWontThrow;

/// Enqueues a signal in the event loop of the AsyncSignal owner's thread,
/// which allows a foreign thread to trigger the callback handler safely.
shared final class AsyncSignal
{
	private void delegate() m_sgh;
nothrow:
private:
	Thread m_owner;
	EventLoop m_evLoop;
	fd_t m_evId;
	Mutex m_mutex;

	void lock() @trusted const nothrow
	{ assumeWontThrow((cast(Mutex) m_mutex).lock()); }

	void unlock() @trusted const nothrow
	{ assumeWontThrow((cast(Mutex) m_mutex).unlock()); }

public:

	///
	this(EventLoop evl)
	in {
		assert(evl !is null);
	}
	body {
		m_evLoop = cast(shared) evl;
		import core.thread : Thread;
		m_owner = cast(shared) Thread.getThis();
		m_mutex = cast(shared) new Mutex;

		version(Posix) {
			static if (EPOLL) {
				import core.sys.posix.pthread : pthread_self;
				m_pthreadId = cast(shared)pthread_self();
			} else /* if KQUEUE */ {
				m_owner_id = cast(shared) g_threadId;
			}
		}
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
	bool run(void delegate() del)
	in {
		debug assert(Thread.getThis() is cast(Thread)m_owner);
	}
	body {
		lock();
		scope (exit) unlock();

		m_sgh = cast(void delegate()) del;

		m_evId = (cast(EventLoop) m_evLoop).run(this);
		if (m_evId != fd_t.init)
			return true;
		else
			return false;
	}

	/// Cleans up underlying resources. This object must be run() again afterwards to be valid
	bool kill()
	in {
		debug assert(Thread.getThis() is cast(Thread)m_owner);
	}
	body {
		return (cast(EventLoop)m_evLoop).kill(cast(shared AsyncSignal) this);
	}

	/// Triggers the handler in its local thread
	bool trigger(EventLoop evl) {
		lock();
		scope (exit) unlock();
		return evl.notify(m_evId, this);
	}

	/// ditto
	bool trigger() {
		lock();
		scope (exit) unlock();
		return (cast(EventLoop)m_evLoop).notify(m_evId, this);
	}

	/// Returns the Thread that created this object.
	@property Thread owner() const {
		lock();
		scope (exit) unlock();
		return cast(Thread) m_owner;
	}

	///
	@property fd_t id() const {
		return m_evId;
	}

package:
	version(Posix) mixin EvInfoMixinsShared;

	void handler() {
		try m_sgh();
		catch (Throwable) {}
		return;
	}
}

package shared struct SignalHandler {
	AsyncSignal ctxt;
	void function(shared AsyncSignal) fct;

	void opCall(shared AsyncSignal ctxt) {
		assert(ctxt !is null);
		fct(ctxt);
		return;
	}
}


/**
	Determines if the given list of types has any non-immutable and unshared aliasing outside of their object tree.

	The types in particular may only contain plain data, pointers or arrays to immutable or shared data, or references
	encapsulated in stdx.typecons.Isolated. Values that do not have unshared and unisolated aliasing are safe to be passed
	between threads.
*/
template isWeaklyIsolated(T...)
{
	import std.typecons : Rebindable;
	static if (T.length == 0) enum bool isWeaklyIsolated = true;
	else static if (T.length > 1) enum bool isWeaklyIsolated = isWeaklyIsolated!(T[0 .. $/2]) && isWeaklyIsolated!(T[$/2 .. $]);
	else {
		static if(is(T[0] == immutable)) enum bool isWeaklyIsolated = true;
		else static if (is(T[0] == shared)) enum bool isWeaklyIsolated = true;
		else static if (isInstanceOf!(Rebindable, T[0])) enum bool isWeaklyIsolated = isWeaklyIsolated!(typeof(T[0].get()));
		else static if (is(T[0] : Throwable)) enum bool isWeaklyIsolated = true; // WARNING: this is unsafe, but needed for send/receive!
		else static if (is(typeof(T[0].__isIsolatedType))) enum bool isWeaklyIsolated = true;
		else static if (is(typeof(T[0].__isWeakIsolatedType))) enum bool isWeaklyIsolated = true;
		else static if (is(T[0] == class)) enum bool isWeaklyIsolated = false;
		else static if (is(T[0] == interface)) enum bool isWeaklyIsolated = false; // can't know if the implementation is isolated
		else static if (is(T[0] == delegate)) enum bool isWeaklyIsolated = T[0].stringof.endsWith(" shared"); // can't know to what a delegate points - FIXME: use something better than a string comparison
		else static if (isDynamicArray!(T[0])) enum bool isWeaklyIsolated = is(typeof(T[0].init[0]) == immutable);
		else static if (isAssociativeArray!(T[0])) enum bool isWeaklyIsolated = false; // TODO: be less strict here
		else static if (isSomeFunction!(T[0])) enum bool isWeaklyIsolated = true; // functions are immutable
		else static if (isPointer!(T[0])) enum bool isWeaklyIsolated = is(typeof(*T[0].init) == immutable) || is(typeof(*T[0].init) == shared);
		else static if (isAggregateType!(T[0])) enum bool isWeaklyIsolated = isWeaklyIsolated!(FieldTypeTuple!(T[0]));
		else enum bool isWeaklyIsolated = true;
	}
}
