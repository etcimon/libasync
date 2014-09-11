module event.file;
import event.types;
import event.events;
import core.thread : Thread, ThreadGroup;
import core.sync.mutex;
import core.sync.condition;
import std.stdio : File;
import core.atomic;

nothrow {

	__gshared Mutex gs_wlock;
	__gshared Array!(void*) gs_waiters; // Array!(shared AsyncSignal)
	__gshared Condition gs_started;

	__gshared Mutex gs_tlock;
	__gshared ThreadGroup gs_threads; // daemon threads
	shared(int) gs_threadCnt;

}
struct FileCmdInfo
{
	FileCmd command;
	string filePath;
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

	/// todo: define custom errors
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

	bool read(string file_path, size_t len = 128, size_t off = -1) {
		return read(file_path, new shared ubyte[len], off);
	}

	bool read(string file_path, shared ubyte[] buffer, size_t off = -1) 
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

	bool write(string file_path, shared ubyte[] buffer, size_t off = -1) 
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

	bool append(string file_path, shared ubyte[] buffer)
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
					Thread thr = new FileCmdProcessor;
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
		cmd_handler.trigger(cast(EventLoop)m_evLoop, cast(shared void*)this);
		return true;
	}

	synchronized void handler() {
		try m_handler();
		catch (Throwable e) {
			import std.stdio : writeln;
			try writeln("Failed to send command. ", e.toString()); catch {}
		}
	}

	synchronized @property string filePath() {
		return m_cmdInfo.filePath;
	}

	synchronized @property void filePath(string file_path) {
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

enum FileCmd {
	READ,
	WRITE,
	APPEND
}

final class FileCmdProcessor : Thread 
{
nothrow:
private:
	EventLoop m_evLoop;
	shared AsyncSignal m_waiter;
	bool m_stop;

	this() {
		try super(&run);
		catch (Throwable e) {
			import std.stdio;
			try writeln("Failed to run thread ... ", e.toString()); catch {}
		}
	}

	void process(shared AsyncFile ctxt) {
		auto mutex = ctxt.m_cmdInfo.mtx;
		FileCmd cmd;
		shared AsyncSignal waiter;
		try synchronized(mutex) {
			cmd = ctxt.m_cmdInfo.command; 
			waiter = ctxt.m_cmdInfo.waiter;
		} catch {}

		import std.stdio;

		try writeln("Processing command: ", cmd); catch {}
		assert(m_waiter is waiter, "File processor is handling a command from the wrong thread");


		try final switch (cmd)
		{
			case FileCmd.READ:
				File file = File(ctxt.filePath, "r");
				if (ctxt.offset != -1)
					file.seek(ctxt.offset);
				ubyte[] res;
				synchronized(mutex) res = file.rawRead(cast(ubyte[])ctxt.buffer);
				if (res)
					ctxt.offset = cast(size_t) (ctxt.offset + res.length);

				break;

			case FileCmd.WRITE:
				File file = File(ctxt.filePath, "w");
				if (ctxt.offset != -1)
					file.seek(ctxt.offset);
				synchronized(mutex) file.rawWrite(cast(ubyte[])ctxt.buffer);
				ctxt.offset = cast(size_t) (ctxt.offset + ctxt.buffer.length);
				break;

			case FileCmd.APPEND:

				File file = File(ctxt.filePath, "a");
				synchronized(mutex) file.rawWrite(cast(ubyte[]) ctxt.buffer);
				ctxt.offset = cast(size_t) file.size();
				break;
		} catch (Throwable e) {
			auto status = StatusInfo.init;
			status.code = Status.ERROR;
			try status.text = e.toString(); catch {}
			ctxt.status = status;
		}

		ctxt.handler();

		try {
			synchronized(gs_wlock)
				gs_waiters.insertBack(cast(void*) m_waiter);
			gs_started.notifyAll(); // saves some waiting on a new thread
		}
		catch (Throwable e) {
			ctxt.m_status.code = Status.ERROR;
			try ctxt.m_status.text = e.toString(); catch {}
		}
	}

	void run()
	{
		m_evLoop = new EventLoop;
		m_waiter = new shared AsyncSignal(m_evLoop);
		m_waiter.setContext(this);
		m_waiter.run(makeHandler(m_waiter));
		try {
			synchronized(gs_wlock) {
				gs_waiters.insertBack(cast(void*)m_waiter);
			}

			gs_started.notifyAll();
		} catch {}

		while(!m_stop && m_evLoop.loop()) continue;
	}

	SignalHandler makeHandler(shared AsyncSignal waiter) {
		SignalHandler eh;
		eh.ctxt = waiter;
		eh.fct = (shared AsyncSignal ev) {
			FileCmdProcessor this_ = ev.getContext!FileCmdProcessor();
			shared AsyncFile ctxt = ev.getMessage!(shared AsyncFile)();

			if (ctxt is null)
			{
				this_.m_stop = true;
				return;
			}

			this_.process(ctxt);
			return;
		};
		
		return eh;
	}
}

shared static this() {
	gs_tlock = new Mutex;
	gs_wlock = new Mutex;
	gs_threads = new ThreadGroup;
	gs_started = new Condition(gs_wlock);

	foreach (i; 0 .. 4) {
		Thread thr = new FileCmdProcessor;
		thr.start();
		gs_threads.add(thr);
	}
	gs_threadCnt = cast(int) 4;
}

void destroyFileThreads() {
	try while (core.atomic.atomicLoad(gs_threadCnt) > 0) {
		synchronized (gs_wlock) {
			foreach (void* sig; gs_waiters[]) {
				shared AsyncSignal signal = cast(shared AsyncSignal) sig;
				signal.trigger();
				core.atomic.atomicOp!"-="(gs_threadCnt, cast(int) 1);

			}
			gs_waiters.clear();
		}
		Thread.sleep(10.usecs);
	} catch (Throwable e) {
		import std.stdio : writeln;
		writeln(e.toString());
	}

}