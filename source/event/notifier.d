module event.notifier;

import event.types;
import event.events;

final class AsyncNotifier
{
nothrow:
private:
	EventLoop m_evLoop;
	NotifierHandler m_evh;
	fd_t m_evId;
	void* m_message;
	void* m_ctxt;
	version(Posix) static if (EPOLL) {
		shared ushort m_owner;
	}
	
public:	
	this(EventLoop evl) 
	in {
		assert(evl !is null);
	}
	body {
		m_evLoop = evl;
	}
		
	mixin DefStatus;

	mixin ContextMgr;
	
	T getMessage(T)()
		if (isPointer!T)
	{
		return cast(T) m_message;
	}
	
	T getMessage(T)()
		if (is(T == class))
	{
		return cast(T) m_message;
	}

	
	bool run(NotifierHandler del) 
	{
		m_evh = del;
		m_evId = m_evLoop.run(this);
		if (m_evId != fd_t.init)
			return true;
		else
			return false;
	}
	
	bool kill() 
	{
		return m_evLoop.kill(this);
	}

	bool trigger(T)(T msg)
	{
		import std.traits : isSomeString;
		static if (isPointer!T)
			m_message = cast(void*) msg;
		else static  if (is(T == class))
			m_message = cast(void*)msg;
		else {
			T* msgPtr = new T;
			m_message = cast(void*) msgPtr;
		}

		return m_evLoop.notify(m_evId, this);
	}
	
package:

	version(Posix) mixin EvInfoMixins;

	@property id() const {
		return m_evId;
	}

	void handler() {
		try m_evh();
		catch {}
		return;
	}
}

struct NotifierHandler {
	AsyncNotifier ctxt;
	void function(AsyncNotifier ctxt) fct;
	
	void opCall() {
		assert(ctxt !is null);
		fct(ctxt);
		return;
	}
}