module libasync.file;
import libasync.types;
import libasync.events;
import core.thread : Thread, ThreadGroup;
import core.sync.mutex;
import core.sync.condition;
import std.stdio;
import core.atomic;
import libasync.internals.path;
import libasync.threads;
import std.file;
import libasync.internals.memory;

/// Runs all blocking file I/O commands in a thread pool and calls the handler
/// upon completion.
shared final class AsyncFile
{
nothrow:
private:
	EventLoop m_evLoop;
	bool m_busy;
	bool m_error;
	FileReadyHandler m_handler;
	FileCmdInfo m_cmdInfo;
	StatusInfo m_status;
	ulong m_cursorOffset;
	Thread m_owner;
	File* m_file;

public:
	this(EventLoop evl) {
		m_evLoop = cast(shared) evl;
		m_cmdInfo.ready = new shared AsyncSignal(cast(EventLoop)m_evLoop);
		m_cmdInfo.ready.run(cast(void delegate())&handler);
		m_owner = cast(shared)Thread.getThis();
		m_file = cast(shared)new File;
		try m_cmdInfo.mtx = cast(shared) new Mutex; catch {}
	}

	/// Cleans up the underlying resources. todo: make this dispose?
	bool kill() {
		scope(failure) assert(false);
		if (file.isOpen)
			(cast()*m_file).close();
		(cast()*m_file).__dtor();
		m_cmdInfo.ready.kill();
		return true;
	}

	synchronized @property StatusInfo status() const
	{
		return cast(StatusInfo) m_status;
	}

	@property string error() const
	{
		return status.text;
	}

	/// Retrieve the buffer from the last command. Must be called upon completion.
	shared(ubyte[]) buffer() {
		try synchronized(m_cmdInfo.mtx)
			return m_cmdInfo.buffer;
		catch {}
		return null;
	}

	/// The current offset updated after the command execution
	synchronized @property ulong offset() const {
		return m_cursorOffset;
	}

	/// Sets the handler called by the owner thread's event loop after the command is completed.
	shared(typeof(this)) onReady(void delegate() del) {
		shared FileReadyHandler handler;
		handler.del = del;
		handler.ctxt = this;
		try synchronized(this) m_handler = handler; catch {}
		return this;
	}

	/// Creates a new buffer with the specified length and uses it to read the
	/// file data at the specified path starting at the specified offset byte.
	bool read(string file_path, size_t len = 128, ulong off = -1, bool create_if_not_exists = true, bool truncate_if_exists = false) {
		return read(file_path, new shared ubyte[len], off, create_if_not_exists, truncate_if_exists);
	}

	/// Reads the file into the buffer starting at offset byte position.
	bool read(string file_path, shared ubyte[] buffer, ulong off = -1, bool create_if_not_exists = true, bool truncate_if_exists = false) 
	in { 
		assert(!m_busy, "File is busy or closed");
		assert(m_handler.ctxt !is null, "AsyncFile must be run before being operated on.");
	}
	body {
		if (buffer.length == 0) {
			try m_handler(); catch { return false; }
			return true;
		}
		try {
			file_path = Path(file_path).toNativeString();
			bool flag;
			if (create_if_not_exists && !m_file && !exists(file_path))
				flag = true;
			else if (truncate_if_exists && (m_file || exists(file_path)))
				flag = true;
			if (flag) // touch
			{	
				if (file.isOpen) 
					file.close();
				import std.c.stdio;
				import std.string : toStringz;
				FILE * f = fopen(file_path.toStringz, "w\0".ptr);
				fclose(f);
			}
			
			if (!file.isOpen || m_cmdInfo.command != FileCmd.READ) {
				auto tmp = File(file_path, "rb");
				file = tmp;
				m_cmdInfo.command = FileCmd.READ;
			}
			if (buffer.length < 65_536) {
				m_cmdInfo.buffer = cast(shared(ubyte[])) buffer;

				if (off != -1)
					file.seek(cast(long)off);
				ubyte[] res;
				res = file.rawRead(cast(ubyte[])buffer);
				if (res)
					m_cursorOffset = cast(shared(ulong)) (off + res.length);
				m_handler();
				return true;
			}
		} catch (Exception e) {
			auto status = StatusInfo.init;
			status.code = Status.ERROR;
			try status.text = "Error in read, " ~ e.toString(); catch {}
			m_status = cast(shared) status;
			return false;
		}
		try synchronized(m_cmdInfo.mtx) { 
			m_cmdInfo.buffer = buffer;
			m_cmdInfo.command = FileCmd.READ;
			filePath = Path(file_path);
		} catch {}
		offset = off;
		return sendCommand();
	}

	/// Writes the data from the buffer into the file at the specified path starting at the
	/// given offset byte position.
	bool write(string file_path, shared const(ubyte)[] buffer, ulong off = -1, bool create_if_not_exists = true, bool truncate_if_exists = false) 
	in { 
		assert(!m_busy, "File is busy or closed"); 
		assert(m_handler.ctxt !is null, "AsyncFile must be run before being operated on.");
	}
	body {
		if (buffer.length == 0) {
			try m_handler(); catch { return false; }
			return true;
		}
		try {

			file_path = Path(file_path).toNativeString();
			bool flag;
			if (create_if_not_exists && !m_file && !exists(file_path))
				flag = true;
			else if (truncate_if_exists && (m_file || exists(file_path)))
				flag = true;
			if (flag) // touch
			{	
				if (file.isOpen) 
					file.close();
				import std.c.stdio;
				import std.string : toStringz;
				FILE * f = fopen(file_path.toStringz, "w\0".ptr);
				fclose(f);
			}
			
			if (!file.isOpen || m_cmdInfo.command != FileCmd.WRITE) {
				auto tmp = File(file_path, "r+b");
				file = tmp;
				m_cmdInfo.command = FileCmd.WRITE;
			}

			if (buffer.length < 65_536) {
				m_cmdInfo.buffer = cast(shared(ubyte[])) buffer;
				if (off != -1)
					file.seek(cast(long)off);
				file.rawWrite(cast(ubyte[])buffer);
				file.flush();
				m_cursorOffset = cast(shared(ulong)) (off + buffer.length);
				m_handler();
				return true;
			}
		} catch (Exception e) {
			auto status = StatusInfo.init;
			status.code = Status.ERROR;
			try status.text = "Error in write, " ~ e.toString(); catch {}
			m_status = cast(shared) status;
			return false;
		}
		try synchronized(m_cmdInfo.mtx) { 
			m_cmdInfo.buffer = cast(shared(ubyte[])) buffer;
			m_cmdInfo.command = FileCmd.WRITE;
			filePath = Path(file_path);
		} catch {}
		offset = off;
		return sendCommand();

	}

	/// Appends the data from the buffer into a file at the specified path.
	bool append(string file_path, shared ubyte[] buffer, bool create_if_not_exists = true, bool truncate_if_exists = false)
	in {
		assert(!m_busy, "File is busy or closed");
		assert(m_handler.ctxt !is null, "AsyncFile must be run before being operated on.");
	}
	body {
		if (buffer.length == 0) {
			try m_handler(); catch { return false; }
			return true;
		}
		try {
			file_path = Path(file_path).toNativeString();
			bool flag;
			if (create_if_not_exists && !m_file && !exists(file_path))
				flag = true;
			else if (truncate_if_exists && (m_file || exists(file_path)))
				flag = true;
			if (flag) // touch
			{	
				if (file.isOpen) 
					file.close();
				import std.c.stdio;
				import std.string : toStringz;
				FILE * f = fopen(file_path.toStringz, "w\0".ptr);
				fclose(f);
			}
			
			if (!file.isOpen || m_cmdInfo.command != FileCmd.APPEND) {
				auto tmp = File(file_path, "a+");
				file = tmp;
				m_cmdInfo.command = FileCmd.APPEND;
			}
			if (buffer.length < 65_536) {
				m_cmdInfo.buffer = cast(shared(ubyte[])) buffer;
				file.rawWrite(cast(ubyte[]) buffer);
				m_cursorOffset = cast(shared(ulong)) file.size();
				file.flush();
				m_handler();
				return true;
			}
		} catch (Exception e) {
			auto status = StatusInfo.init;
			status.code = Status.ERROR;
			try status.text = "Error in append, " ~ e.toString(); catch {}
			m_status = cast(shared) status;
			return false;
		}
		try synchronized(m_cmdInfo.mtx) { 
			m_cmdInfo.buffer = cast(shared(ubyte[])) buffer;
			m_cmdInfo.command = FileCmd.APPEND;
			filePath = Path(file_path);
		} catch {}
		return sendCommand();
	}

	private bool sendCommand() 
	in { assert(!waiting, "File is busy or closed"); }
	body {
		waiting = true;
		m_error = false;
		status = StatusInfo.init;

		Waiter cmd_handler;

		try {
			cmd_handler = popWaiter();
		
		} catch (Throwable e) {
			import std.stdio;
			try {
				status = StatusInfo(Status.ERROR, e.toString());
				m_error = true;
			} catch {}
			
			return false;
		}

		assert(cmd_handler.cond, "Could not lock a thread for async operations. Note: Async file I/O in static constructors is unsupported.");
		
		m_cmdInfo.waiter = cast(shared) cmd_handler;
		try {
			synchronized(gs_wlock)
				gs_jobs.insert(CommandInfo(CmdInfoType.FILE, cast(void*) this));
			cmd_handler.cond.notifyAll();
		}
		catch (Exception e){
			import std.stdio;
			try writeln("Exception occured notifying foreign thread: ", e); catch {}
		}
		return true;
	}
package:

	synchronized @property FileCmdInfo cmdInfo() {
		return m_cmdInfo;
	}

	synchronized @property Path filePath() {
		return cast(Path) m_cmdInfo.filePath;
	}

	synchronized @property bool waiting() const {
		return cast(bool) m_busy;
	}

	synchronized @property void filePath(Path file_path) {
		m_cmdInfo.filePath = cast(shared) file_path;
	}

	synchronized @property File file() {
		scope(failure) assert(false);
		return cast()*m_file;
	}

	synchronized @property void file(ref File f) {
		try (cast()*m_file).opAssign(f);
		catch (Exception e) {
			import std.stdio : writeln;
			try writeln(e.msg); catch {}
		}
	}
	
	synchronized @property void status(StatusInfo stat) {
		m_status = cast(shared) stat;
	}
	
	synchronized @property void offset(ulong val) {
		m_cursorOffset = cast(shared) val;
	}

	synchronized @property void waiting(bool b) {
		m_busy = cast(shared) b;
	}

	void handler() {
		try m_handler();
		catch (Throwable e) {
			import std.stdio : writeln;
			try writeln("Failed to send command. ", e.toString()); catch {}
		}
	}
}

package enum FileCmd {
	READ,
	WRITE,
	APPEND
}

package shared struct FileCmdInfo
{
	FileCmd command;
	Path filePath;
	ubyte[] buffer;
	Waiter waiter;
	AsyncSignal ready;
	AsyncFile file;
	Mutex mtx; // for buffer writing
}

package shared struct FileReadyHandler {
	AsyncFile ctxt;
	void delegate() del;
	
	void opCall() {
		assert(ctxt !is null);
		ctxt.waiting = false;
		del();
		return;
	}
}
