module event.filesystem;
version(none):
import event.types;
import event.events;
import event.stack;
import core.thread : Thread, ThreadGroup;
import core.sync.mutex;

nothrow:

__gshared Mutex gs_wlock;
__gshared Stack!(shared AsyncEvent) gs_waiters;

__gshared Mutex gs_tlock;
__gshared ThreadGroup gs_threads;

final class AsyncFile
{
nothrow:
private:
	EventLoop m_evLoop;
	string m_filePath;
	FileReadyHandler m_handler;
	bool m_open;
	bool m_busy;
	void* m_context;

public:
	this(EventLoop evl) {
		m_evLoop = evl;
	}

	// todo: define custom status
	@property StatusInfo status() const
	{
		return StatusInfo.init;
	}
	
	/// todo: define custom errors
	@property string error() const 
	{
		return "";
	}

	mixin ContextMgr;

	bool run(FileReadyHandler del)
	in { assert(!m_open); }
	body {
		m_handler = del;
		return true;
	}

	bool open(string file_path) 
	in { assert(!m_busy); }
	body {
		m_filePath = file_path;
		m_open = true;
		return true;
	}

	bool read(shared ubyte[] buffer, long offset = -1) 
	in { assert(!m_busy && m_open); }
	body {

		shared FileCmdInfo cmd_info = new shared FileCmdInfo;
		cmd_info.command = FileCmd.READ;
		cmd_info.buffer = buffer;
		cmd_info.offset = offset;
		cmd_info.replyReady = reply_ready;
		return sendCommand(cmd_info);
	}

	bool write(shared ubyte[] buffer, long offset = -1) 
	in { assert(!m_busy && m_open); }
	body {
		shared FileCmdInfo cmd_info = new shared FileCmdInfo;
		cmd_info.command = FileCmd.WRITE;
		cmd_info.buffer = buffer;
		cmd_info.offset = offset;
		cmd_info.replyReady = reply_ready;
		return sendCommand(cmd_info);

	}

	bool append(shared ubyte[] buffer, long offset = -1)
	in { assert(!m_busy && m_open); }
	body {
		shared FileCmdInfo cmd_info = new shared FileCmdInfo;
		cmd_info.command = FileCmd.APPEND;
		cmd_info.buffer = buffer;
		cmd_info.offset = offset;
		cmd_info.replyReady = reply_ready;
		return sendCommand(cmd_info);
	}

private:
	bool sendCommand(shared FileCmdInfo cmd) 
	in { assert(!m_busy && m_open); }
	body {
		m_busy = true;

		shared AsyncEvent reply_ready = new shared AsyncEvent;
		shared EventHandler reply_ready_ev;
		
		reply_ready.setContext(this);

		reply_ready_ev.ctxt = reply_ready;
		reply_ready_ev.fct = (AsyncEvent ev) {
			AsyncFile this_ = ev.getContext!AsyncFile();
			shared FileReplyInfo reply = ev.getMessage!(shared FileReplyInfo)();
			this_.m_busy = false;
			synchronized(gs_wlock) {
				gs_waiters.push(reply.waiter);
			}
			this_.handler();
			
		};

		shared AsyncEvent cmd_handler;
		bool start_thread;
		synchronized(gs_wlock) {
			try cmd_handler = gs_waiters.pop();
			catch (Exception e) {
				start_thread = true;
			}
		}

		if (start_thread) {
			Thread thr = new FileCmdProcessor;
			thr.start();
			gs_threads.add(thr);
		}
		// todo: find a better way out of this...
		while(start_thread && !cmd_handler) {
			import std.datetime : usecs;
			Thread.sleep(1.usecs);

			synchronized(gs_wlock) {
				try cmd_handler = gs_waiters.pop();
				catch {}
			}
		}

		assert(cmd_handler);

		cmd.waiter = cmd_handler;

		reply_ready.run(reply_ready_ev);
		cmd_handler.trigger(m_evLoop, cmd);
		return true;
	}

	@property FileReadyHandler handler() {
		return m_handler;
	}
}

shared struct FileReadyHandler {
	shared AsyncFile ctxt;
	void function(shared AsyncFile ctxt, long offset) fct;
	
	void opCall(long offset) {
		assert(ctxt !is null);
		fct(ctxt, offset);
		return;
	}
}

enum FileCmd {
	READ,
	WRITE,
	APPEND
}

shared final class FileCmdInfo
{
	string fileName;
	FileCmd command;
	ubyte[] buffer;
	long startOffset;
	AsyncEvent replyReady;
	AsyncEvent waiter;
}

shared final class FileReplyInfo {
	bool error;
	string error_msg;
	long cursorOffset;
	AsyncEvent waiter;
}

final class FileCmdProcessor : Thread 
{
nothrow:
private:
	EventLoop m_evLoop;

	this() {
		super(&run);
	}

	void process(shared FileCmdInfo cmd) {
		shared FileReplyInfo reply = new shared FileReplyInfo;
		reply.waiter = cmd.waiter;

		import std.stdio : File;

		final switch (cmd)
		{
			case FileCmd.READ:
				try {
					File file = File(cmd.fileName, "r");
					file.seek(cmd.startOffset);
					auto res = file.rawRead(cmd.buffer);
					if (res)
						reply.cursorOffset = res.length;

				}
				catch (Exception e) {
					reply.error = true;
					reply.error_msg = e.msg;
				}

				break;

			case FileCmd.WRITE:
				try {
					File file = File(cmd.fileName, "w");
					file.seek(cmd.startOffset);
					file.rawWrite(cmd.buffer);
					reply.cursorOffset = cmd.startOffset + cmd.buffer.length;
				}
				catch (Exception e) {
					reply.error = true;
					reply.error_msg = e.msg;
				}

				break;

			case FileCmd.APPEND:

				try {
					File file = File(cmd.fileName, "a");
					file.seek(cmd.startOffset);
					file.rawWrite(cmd.buffer);
					reply.cursorOffset = cmd.startOffset + cmd.buffer.length;
				}
				catch (Exception e) {
					reply.error = true;
					reply.error_msg = e.msg;
				}

				break;
		}

		cmd.replyReady.trigger(m_evLoop, reply);
	}

	void run()
	{
		m_evLoop = new EventLoop;
		shared AsyncEvent job_watcher = new shared AsyncEvent(m_evLoop);
		job_watcher.setContext(this);
		job_watcher.run(makeHandler(job_watcher));

		synchronized(gs_wlock) {
			gs_waiters.add(job_watcher);
		}

		while(true) {
			m_evLoop.loop();
		}
	}

	EventHandler makeHandler(shared AsyncEvent ctxt) {
		EventHandler eh;
		eh.ctxt = ctxt;
		eh.fct = (AsyncEvent ev) {
			shared FileCmdInfo cmd_info = ev.getMessage!(shared FileCmdInfo)();
			FileCmdProcessor this_ = ev.getContext!FileCmdProcessor();
			this_.process(cmd_info);
			return;
		};
		
		return eh;
	}
}

shared static this() {
	foreach (i; 0 .. 4) {
		Thread thr = new FileCmdProcessor;
		thr.start();
		gs_threads.add(thr);
	}

}