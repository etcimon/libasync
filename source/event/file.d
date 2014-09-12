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

struct FileCmdInfo
{
	FileCmd command;
	Path filePath;
	ubyte[] buffer;
	shared AsyncSignal waiter;
	shared AsyncFile file;
	Mutex mtx; // for buffer writing
}

shared final class AsyncFile
{
nothrow:
private:
	EventLoop m_evLoop;
	FileReadyHandler m_handler;
	bool m_busy;
	bool m_error;
	FileCmdInfo m_cmdInfo;
	StatusInfo m_status;
	size_t m_cursorOffset;
	void* m_ctxt;
	Thread m_owner;

public:
	this(EventLoop evl) {
		m_evLoop = cast(shared) evl;
		m_owner = cast(shared)Thread.getThis();
		try m_cmdInfo.mtx = cast(shared) new Mutex; catch {}
	}

	synchronized @property StatusInfo status() const
	{
		return m_status;
	}

	@property string error() const
	{
		return status.text;
	}

	@property bool waiting() const {
		return m_busy;
	}

	synchronized T getContext(T)() 
	if (isPointer!T)
	{
		return cast(T*) m_ctxt;
	}
	
	synchronized T getContext(T)() 
		if (is(T == class))
	{
		return cast(T) m_ctxt;
	}

	synchronized void setContext(T)(T ctxt)
		if (isPointer!T || is(T == class))
	{
		m_ctxt = cast(shared(void*)) ctxt;
	}

	synchronized @property size_t offset() const {
		return m_cursorOffset;
	}

	synchronized bool run(FileReadyHandler del)
	body {
		m_handler = del;
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
	in { assert(!m_busy, "File is busy or closed"); }
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
	in { assert(!m_busy, "File is busy or closed"); }
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
	in { assert(!m_busy, "File is busy or closed"); }
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
	bool sendCommand() 
	in { assert(!m_busy, "File is busy or closed"); }
	body {
		m_busy = true;
		m_status = StatusInfo.init;

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
			try writeln(e.toString()); catch {}

		}
		assert(cmd_handler);
		m_cmdInfo.waiter = cmd_handler;
		cmd_handler.trigger!(shared void*)(cast(EventLoop)m_evLoop, cast(shared void*)this);
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
		return m_cmdInfo.filePath;
	}

	synchronized @property void filePath(Path file_path) {
		m_cmdInfo.filePath = file_path;
	}

	synchronized @property void status(StatusInfo stat) {
		m_status = stat;
	}
	
	synchronized @property void offset(size_t val) {
		m_cursorOffset = val;
	}
}

shared struct FileReadyHandler {
	AsyncFile ctxt;
	void function(shared AsyncFile ctxt) fct;
	
	void opCall() {
		assert(ctxt !is null);
		fct(ctxt);
		return;
	}
}
