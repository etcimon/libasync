///
module libasync.watcher;

import libasync.types;

import libasync.events;
import libasync.internals.path;
import std.container : Array;
import std.file;

/// Watches one or more directories in the local filesystem for the specified events
/// by calling a custom event handler asynchroneously when they occur.
///
/// Usage: run() the object, start watching directories, receive an event in your handler,
/// read the changes by draining the buffer.
final nothrow class AsyncDirectoryWatcher
{
nothrow:
private:
	EventLoop m_evLoop;
	Array!WatchInfo m_directories;
	fd_t m_fd;
	debug bool m_dataRemaining;
public:
	///
	this(EventLoop evl)
	in { assert(evl !is null); }
	body { m_evLoop = evl; }

	mixin DefStatus;

	/// Fills the buffer with file/folder events and returns the number
	/// of events consumed. Returns 0 when the buffer is drained.
	uint readChanges(ref DWChangeInfo[] dst) {
		uint cnt = m_evLoop.readChanges(m_fd, dst);

		debug {
			if (cnt < dst.length)
				m_dataRemaining = false;
		}
		return cnt;
	}

	/// Registers the object in the underlying event loop and sends notifications
	/// related to buffer activity by calling the specified handler.
	bool run(void delegate() del) {
		DWHandler handler;
		handler.del = del;
		handler.ctxt = this;

		m_fd = m_evLoop.run(this, handler);
		// import std.stdio;
		// try writeln("Running with FD: ", m_fd); catch {}

		if (m_fd == fd_t.init)
			return false;
		return true;
	}

	/// Starts watching for file events in the specified directory,
	/// recursing into subdirectories will add those and its files
	/// to the watch list as well.
	bool watchDir(string path, DWFileEvent ev = DWFileEvent.ALL, bool recursive = false) {

		try
		{
			path = Path(path).toNativeString();
			//import std.stdio;
			//writeln("Watching ", path);
			bool addWatch() {
				WatchInfo info;
				info.events = ev;
				try info.path = Path(path); catch (Exception) {}
				info.recursive = recursive;

				//writeln("Watch: ", info.path.toNativeString());
				uint wd = m_evLoop.watch(m_fd, info);
				//writeln("Watching WD: ", wd);
				if (wd == 0 && m_evLoop.status.code != Status.OK)
					return false;
				info.wd = wd;
				try m_directories.insert(info); catch (Exception) {}
				return true;
			}

			if (!addWatch())
				return false;

		}
		catch (Exception e) {
			static if (DEBUG) {
				import std.stdio;
				try writeln("Could not add directory: " ~ e.toString()); catch {}
			}
			return false;
		}

		return true;
	}

	/// Removes the directory and its files from the event watch list.
	/// Recursive will remove all subdirectories in the watch list.
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
		} catch (Exception) {}
		return true;
	}

	/// Cleans up underlying resources.
	bool kill()
	in { assert(m_fd != fd_t.init); }
	body {
		return m_evLoop.kill(this);
	}

	///
	@property fd_t fd() const {
		return m_fd;
	}

package:
	version(Posix) mixin EvInfoMixins;

	@property void fd(fd_t val) {
		m_fd = val;
	}

}

/// Represents one event on one file in a watched directory.
struct DWChangeInfo {
	/// The event triggered by the file/folder
	DWFileEvent event;
	/// The os-independent address of the file/folder
	private Path m_path;

	///
	@property string path() {
		return m_path.toNativeString();
	}

	///
	@property void path(Path p) {
		m_path = p;
	}

}

/// List of events that can be watched for. They must be 'Or'ed together
/// to combined them when calling watch(). OS-triggerd events are exclusive.
enum DWFileEvent : uint {
	ERROR = 0, ///
	MODIFIED = 0x00000002, ///
	MOVED_FROM = 0x00000040, ///
	MOVED_TO = 0x00000080, ///
	CREATED = 0x00000100, ///
	DELETED = 0x00000200, ///
	ALL = MODIFIED | MOVED_FROM | MOVED_TO | CREATED | DELETED ///
}


package struct DWHandler {
	AsyncDirectoryWatcher ctxt;
	void delegate() del;
	void opCall(){
		assert(ctxt !is null);
		debug ctxt.m_dataRemaining = true;
		del();
		debug {
			assert(!ctxt.m_dataRemaining, "You must read all changes when you receive a notification for directory changes");
		}
		assert(ctxt !is null);
		return;
	}
}

package struct WatchInfo {
	DWFileEvent events;
	Path path;
	bool recursive;
	uint wd; // watch descriptor
}
