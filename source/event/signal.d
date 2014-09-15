module event.signal;
import std.traits;

import event.types;
import event.events;
import core.thread;

/// Cross-threading utility, considered thread safe and declarable __gshared or shared
/// Can also be used lockless in thread-local instances
shared final class AsyncSignal
{
	private void delegate() m_sgh;
nothrow:
private:
	Thread m_owner;
	shared(size_t)* m_owner_id;
	EventLoop m_evLoop;

	version(Posix) EventInfo* m_evInfo;
	fd_t m_evId;

public:

	this(EventLoop evl) 
	in {
		assert(evl !is null);
	}
	body {
		import core.thread : Thread;
		m_evLoop = cast(shared) evl;
		m_owner = cast(shared) Thread.getThis();
		version(Posix) static if (!EPOLL) m_owner_id = cast(shared) g_threadId;
	}
			
	@property bool hasError() const 
	{
		return (cast(EventLoop)m_evLoop).status.code != Status.OK;
	}

	@property StatusInfo status() const {
		return (cast(EventLoop)m_evLoop).status;
	}

	@property string error() const {
		return (cast(EventLoop)m_evLoop).error;
	}

	bool run(void delegate() del) 
	in {
		assert(Thread.getThis() is cast(Thread)m_owner);
	}
	body {

		m_sgh = cast(void delegate()) del;

		m_evId = (cast(EventLoop) m_evLoop).run(this);
		if (m_evId != fd_t.init)
			return true;
		else
			return false;
	}

	bool kill() 
	in {
		assert(Thread.getThis() is cast(Thread)m_owner);
	}
	body {
		return (cast(EventLoop)m_evLoop).kill(cast(shared AsyncSignal) this);
	}

	synchronized bool trigger(EventLoop evl) {
		return evl.notify(m_evId, this);
	}

	synchronized bool trigger() {
		return (cast(EventLoop)m_evLoop).notify(m_evId, this);
	}

	synchronized @property Thread owner() const {
		return cast(Thread) m_owner;
	}

package:
	synchronized @property size_t threadId() {
		return cast(size_t) *m_owner_id;
	}
	version(Posix) {
		@property shared(EventInfo*) evInfo() {
			return m_evInfo;
		}
		
		@property void evInfo(shared(EventInfo*) info) {
			m_evInfo = info;
		}
	}
	@property id() const {
		return m_evId;
	}

	void handler() {
		try m_sgh();
		catch {}
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
