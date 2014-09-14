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

enum FileCmd {
	READ,
	WRITE,
	APPEND
}

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
	size_t m_cursorOffset;
	Thread m_owner;

public:
	this(EventLoop evl) {
		m_evLoop = cast(shared) evl;
		m_owner = cast(shared)Thread.getThis();
		try m_cmdInfo.mtx = cast(shared) new Mutex; catch {}
	}

	synchronized @property StatusInfo status() const
	{
		return cast(StatusInfo) m_status;
	}

	@property string error() const
	{
		return status.text;
	}

	synchronized @property bool waiting() const {
		return cast(bool) m_busy;
	}

	synchronized @property size_t offset() const {
		return cast(size_t) m_cursorOffset;
	}

	bool run(void delegate() del) {
		shared FileReadyHandler handler;
		handler.del = del;
		handler.ctxt = this;
		synchronized(this) m_handler = handler;
		return true;
	}

	bool kill() {
		return true;
	}

	shared(ubyte[]) buffer() {
		try synchronized(m_cmdInfo.mtx)
			return m_cmdInfo.buffer;
		catch {}
		return null;
	}

	bool read(Path file_path, size_t len = 128, size_t off = -1) {
		return read(file_path, new shared ubyte[len], off);
	}

	bool read(Path file_path, shared ubyte[] buffer, size_t off = -1) 
	in { 
		assert(!m_busy, "File is busy or closed");
		assert(m_handler != FileReadyHandler.init, "AsyncFile must be run before being operated on.");
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

	bool write(Path file_path, shared ubyte[] buffer, size_t off = -1) 
	in { 
		assert(!m_busy, "File is busy or closed"); 
		assert(m_handler != FileReadyHandler.init, "AsyncFile must be run before being operated on.");
	}
	body {
		try synchronized(m_cmdInfo.mtx) { 
			m_cmdInfo.buffer = buffer;
			m_cmdInfo.command = FileCmd.WRITE;
		} catch {}
		filePath = file_path;
		offset = off;
		return sendCommand();

	}

	bool append(Path file_path, shared ubyte[] buffer)
	in {
		assert(!m_busy, "File is busy or closed");
		assert(m_handler != FileReadyHandler.init, "AsyncFile must be run before being operated on.");
	}
	body {
		try synchronized(m_cmdInfo.mtx) { 
			m_cmdInfo.command = FileCmd.APPEND;
			m_cmdInfo.buffer = buffer;
		} catch {}
		filePath = file_path;
		return sendCommand();
	}

private:
	// chooses a thread or starts it if necessary
	void sendCommand() 
	in { assert(!waiting, "File is busy or closed"); }
	body {
		waiting = true;
		m_error = false;
		status = StatusInfo.init;

		shared AsyncSignal cmd_handler;
		try {
			bool start_thread;
			do {
				if (start_thread) {
					Thread thr = new CmdProcessor;
					thr.start();

					core.atomic.atomicOp!"+="(gs_threadCnt, cast(int) 1);
					gs_threads.add(thr);
				}

				synchronized(gs_wlock) {
					if (start_thread && !gs_started.wait(5.seconds))
						continue;

					try {
						if (!cmd_handler && !gs_waiters.empty) {
							cmd_handler = cast(shared AsyncSignal) gs_waiters.back;
							gs_waiters.removeBack();
						}
						else if (core.atomic.atomicLoad(gs_threadCnt) < 16) {
							start_thread = true;
						}
						else {
							Thread.sleep(50.usecs);
						}
					} catch {}
				}
			} while(!cmd_handler);
		} catch (Throwable e) {
			import std.stdio;
			try {
				status = StatusInfo(Status.ERROR, e.toString());
				m_error = true;
			} catch {}

			return false;

		}
		assert(cmd_handler);
		m_cmdInfo.waiter = cmd_handler;
		synchronized(gs_wlock) gs_jobs.insert(CommandInfo(CmdInfoType.FILE, cast(void*) m_cmdInfo));
		cmd_handler.trigger(cast(EventLoop)m_evLoop);
		return true;
	}

	synchronized void handler() {
		try m_handler();
		catch (Throwable e) {
			import std.stdio : writeln;
			try writeln("Failed to send command. ", e.toString()); catch {}
		}
	}

	synchronized @property Path filePath() {
		return cast(Path) m_cmdInfo.filePath;
	}

	synchronized @property void filePath(Path file_path) {
		m_cmdInfo.filePath = cast(shared) file_path;
	}

	synchronized @property void status(StatusInfo stat) {
		m_status = cast(shared) stat;
	}
	
	synchronized @property void offset(size_t val) {
		m_cursorOffset = cast(shared) val;
	}

	synchronized @property void waiting(bool b) {
		m_busy = cast(shared) b;
	}
}

package shared struct FileCmdInfo
{
	FileCmd command;
	Path filePath;
	ubyte[] buffer;
	AsyncSignal waiter;
	AsyncFile file;
	Mutex mtx; // for buffer writing
}

package shared struct FileReadyHandler {
	AsyncFile ctxt;
	void delegate() del;
	
	void opCall() {
		assert(ctxt !is null);
		del();
		return;
	}
}
