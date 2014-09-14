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
	version(Posix) static if (EPOLL) shared ushort m_owner;
	
public:	
	this(EventLoop evl) 
	in {
		assert(evl !is null);
	}
	body {
		m_evLoop = evl;
	}
		
	mixin DefStatus;

	bool run(void delegate() del) {
		NotifierHandler handler;
		handler.del = del;
		handler.ctxt = this;
		return run(handler);
	}

	private bool run(NotifierHandler del) 
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

	bool trigger()
	{		
		return m_evLoop.notify(m_evId, this);
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

package struct NotifierHandler {
	AsyncNotifier ctxt;
	void delegate() del;
	
	void opCall() {
		assert(ctxt !is null);
		del();
		return;
	}
}