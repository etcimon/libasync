module event.watcher;

import event.types;

import event.events;
public import event.internals.path;
import std.container : Array;
import std.file;

package struct WatchInfo {
	DWFileEvent events;
	Path path;
	bool recursive;
	uint wd; // watch descriptor
}

struct DWChangeInfo {
	DWFileEvent event;
	Path path;
}

final nothrow class AsyncDirectoryWatcher
{
nothrow:
private:
	EventLoop m_evLoop;
	DWHandler m_evh;
	Array!WatchInfo m_directories;
	fd_t m_fd;
	
public:
	this(EventLoop evl)
	in { assert(evl !is null); }
	body { m_evLoop = evl; }
	
	mixin DefStatus;

	uint readChanges(ref DWChangeInfo[] dst) {
		return m_evLoop.readChanges(m_fd, dst);
	}

	bool watchDir(string path, DWFileEvent ev = DWFileEvent.ALL, bool recursive = false) {

		try 
		{
			path = Path(path).toString();

			bool addWatch(string subPath) {
				WatchInfo info;
				info.events = ev;
				try info.path = Path(subPath); catch {}
				info.recursive = recursive;
				uint wd = m_evLoop.watch(m_fd, info);
				if (wd == 0 && m_evLoop.status.code != Status.OK)
					return false;
				info.wd = wd;
				try m_directories.insert(info); catch {}
				return true;
			}

			if (!addWatch(path))
				return false;

			if (recursive && path.isDir) {
				foreach (de; path.dirEntries(SpanMode.shallow)) {
					if (de.isDir){
						if (!addWatch(de.name))
							return false;
					}
				}
			} 
		}
		catch {}

		return true;
	}

	bool unwatchDir(string path, bool recursive) {
		import std.algorithm : countUntil;

		try {
			path = Path(path).toString();

			bool removeWatch(string path) {
				auto idx = m_directories[].countUntil!((a,b) => a.path == b)(Path(path));
				if (idx < 0)
					return true;

				if (!m_evLoop.unwatch(m_fd, m_directories[idx].wd))
					return false;

				m_directories.linearRemove(m_directories[idx .. idx+1]);
				return true;
			}
			removeWatch(path);
			if (recursive && path.isDir) {
				foreach (de; path.dirEntries(SpanMode.shallow)) {
					if (de.isDir){
						if (!removeWatch(path))
							return false;
					}
				}
			}
		} catch {}
		return true;
	}

	bool run(void delegate() del) {
		DWHandler handler;
		handler.del = del;
		handler.ctxt = this;

		m_fd = m_evLoop.run(this, handler);

		if (m_fd == fd_t.init)
			return false;
		return true;
	}

	private bool run(DWHandler del)
	in { assert(m_fd == fd_t.init, "Cannot rebind"); }
	body {
		m_evh = del;
		m_fd = m_evLoop.run(this, del);
		if (m_fd == fd_t.init)
			return false;
		else
			return true;
	}
	
	bool kill()
	in { assert(m_fd != fd_t.init); }
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

struct DWHandler {
	AsyncDirectoryWatcher ctxt;
	void delegate() del;
	void opCall(){
		assert(ctxt !is null);
		del();
		debug {
			DWChangeInfo[1] arr;
			DWChangeInfo[] arrRef = arr.ptr[0..1];
			assert(ctxt.readChanges(arrRef) == 0, "You must read all changes when you receive a notification for directory changes");
		}
		assert(ctxt !is null);
		return;
	}
}

enum DWFileEvent : uint {
	ERROR = 0,
	MODIFIED = 0x00000002,
	MOVED_FROM = 0x00000040,
	MOVED_TO = 0x00000080,
	CREATED = 0x00000100, 
	DELETED = 0x00000200,
	ALL = MODIFIED | MOVED_FROM | MOVED_TO | CREATED | DELETED
}