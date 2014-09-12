module event.watcher;

import event.types;

import event.events;

final nothrow class AsyncDirectoryWatcher
{
nothrow:
private:
	EventLoop m_evLoop;
	DWFileEvent m_watching;
	string m_path;
	bool m_recursive;
	fd_t m_fd;
	void* m_ctxt;
	
public:
	this(EventLoop evl)
	in { assert(evl !is null); }
	body { m_evLoop = evl; }
	
	mixin DefStatus;
	
	mixin ContextMgr;

	bool run(DWFileEventHandler del)
	in { assert(m_fd == fd_t.init, "Cannot rebind"); }
	body {
		m_local = addr;
		m_socket = m_evLoop.run(this, del);
		if (m_socket == fd_t.init)
			return false;
		else
			return true;
	}
	
	bool kill()
	in { assert(m_socket != fd_t.init); }
	body {
		return m_evLoop.kill(this);
	}
	
package:
	version(Posix) mixin EvInfoMixins;
	
	@property fd_t fd() const {
		return m_fd;
	}
	
	@property void fd(fd_t val) {
		m_fd = val;
	}
	
}

struct DWFileEventHandler {
	AsyncDirectoryWatcher conn;
	void function(AsyncDirectoryWatcher, DWFileEvent, string) fct;
	void opCall(DWFileEvent code, string file){
		assert(conn !is null);
		fct(conn, code, file);
		assert(conn !is null);
		return;
	}
}

enum DWFileEvent : int {
	ERROR = 0,
	MODIFIED = 0x00000002,
	MOVED_FROM = 0x00000040,
	MOVED_TO = 0x00000080,
	CREATED = 0x00000100, 
	DELETED = 0x00000200
}