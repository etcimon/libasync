module event.file;
import event.types;
import event.events;
import core.thread : Thread, ThreadGroup;
import core.sync.mutex;
import core.sync.condition;
import std.stdio : File;
import core.atomic;
public import event.internals.path;
import event.threads;

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

public:
	this(EventLoop evl) {
		m_evLoop = cast(shared) evl;
		m_cmdInfo.ready = new shared AsyncSignal(cast(EventLoop)m_evLoop);
		m_cmdInfo.ready.run(cast(void delegate())&handler);
		m_owner = cast(shared)Thread.getThis();
		try m_cmdInfo.mtx = cast(shared) new Mutex; catch {}
	}

	/// Cleans up the underlying resources. todo: make this dispose?
	bool kill() {
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
	bool read(Path file_path, size_t len = 128, ulong off = -1) {
		return read(file_path, new shared ubyte[len], off);
	}

	/// Reads the file into the buffer starting at offset byte position.
	bool read(Path file_path, shared ubyte[] buffer, ulong off = -1) 
	in { 
		assert(!m_busy, "File is busy or closed");
		assert(m_handler.ctxt !is null, "AsyncFile must be run before being operated on.");
	}
	body {
		try synchronized(m_cmdInfo.mtx) { 
			m_cmdInfo.buffer = buffer;
			m_cmdInfo.command = FileCmd.READ;
		} catch {}
		filePath = file_path;
		offset = off;
		return sendCommand();
	}

	/// Writes the data from the buffer into the file at the specified path starting at the
	/// given offset byte position.
	bool write(Path file_path, shared const(ubyte)[] buffer, ulong off = -1) 
	in { 
		assert(!m_busy, "File is busy or closed"); 
		assert(m_handler.ctxt !is null, "AsyncFile must be run before being operated on.");
	}
	body {
		try synchronized(m_cmdInfo.mtx) { 
			m_cmdInfo.buffer = cast(shared(ubyte[])) buffer;
			m_cmdInfo.command = FileCmd.WRITE;
		} catch {}
		filePath = file_path;
		offset = off;
		return sendCommand();

	}

	/// Appends the data from the buffer into a file at the specified path.
	bool append(Path file_path, shared ubyte[] buffer)
	in {
		assert(!m_busy, "File is busy or closed");
		assert(m_handler.ctxt !is null, "AsyncFile must be run before being operated on.");
	}
	body {
		try synchronized(m_cmdInfo.mtx) { 
			m_cmdInfo.command = FileCmd.APPEND;
			m_cmdInfo.buffer = buffer;
		} catch {}
		filePath = file_path;
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
		assert(cmd_handler.cond);
		
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
