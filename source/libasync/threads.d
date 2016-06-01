module libasync.threads;
import core.sync.mutex;
import core.sync.condition;
import core.thread;
import libasync.events;
import std.stdio;
import std.container : Array;
import core.atomic;
import std.conv : to;

nothrow {
	struct Waiter {
		Mutex mtx;
		Condition cond;
	}

	__gshared Mutex gs_wlock;
	__gshared Array!Waiter gs_waiters;
	__gshared Array!CommandInfo gs_jobs;
	__gshared Condition gs_started;
	shared(bool) gs_closing;

	__gshared ThreadGroup gs_threads; // daemon threads
	shared(int) gs_threadCnt;

}

final class CmdProcessor : Thread
{
nothrow:
private:
	EventLoop m_evLoop;
	Waiter m_waiter;
	shared(bool) g_stop;

	this() {
		try {
			Mutex mtx = new Mutex;
			Condition cond = new Condition(mtx);
			m_waiter = Waiter(mtx, cond);
			super(&run);
		}
		catch (Throwable e) {
			static if (DEBUG) {
				import std.stdio;
				try writeln("Failed to run thread ... ", e.toString()); catch {}
			}
		}
	}

	void process(shared AsyncDNS ctxt) {
		DNSCmdInfo cmdInfo = ctxt.cmdInfo();
		auto mutex = cmdInfo.mtx;
		DNSCmd cmd;
		Waiter waiter;
		string url;
		cmd = cmdInfo.command;
		waiter = cast(Waiter)cmdInfo.waiter;
		url = cmdInfo.url;
		try assert(m_waiter == waiter, "File processor is handling a command from the wrong thread"); catch {}

		try final switch (cmd)
		{
			case DNSCmd.RESOLVEHOST:
				*ctxt.addr = cast(shared) m_evLoop.resolveHost(url, 0, cmdInfo.ipv6?isIPv6.yes:isIPv6.no);
				break;

			case DNSCmd.RESOLVEIP:
				*ctxt.addr = cast(shared) m_evLoop.resolveIP(url, 0, cmdInfo.ipv6?isIPv6.yes:isIPv6.no);
				break;

		} catch (Throwable e) {
			auto status = StatusInfo.init;
			status.code = Status.ERROR;
			try status.text = e.toString(); catch {}
			ctxt.status = status;
		}

		try {
			cmdInfo.ready.trigger(m_evLoop);
			synchronized(gs_wlock)
				gs_waiters.insertBack(m_waiter);
			gs_started.notifyAll(); // saves some waiting on a new thread
		}
		catch (Throwable e) {
			auto status = StatusInfo.init;
			status.code = Status.ERROR;
			try status.text = e.toString(); catch {}
			ctxt.status = status;
		}
	}

	void process(shared AsyncFile ctxt) {
		auto cmdInfo = ctxt.cmdInfo;
		auto mutex = cmdInfo.mtx;
		FileCmd cmd;
		Waiter waiter;
		cmd = cmdInfo.command;
		waiter = cast(Waiter)cmdInfo.waiter;

		try assert(m_waiter == waiter, "File processor is handling a command from the wrong thread"); catch {}

		try final switch (cmd)
		{
			case FileCmd.READ:
				File file = ctxt.file;
				if (ctxt.offset != -1)
					file.seek(cast(long)ctxt.offset);
				ubyte[] res;
				synchronized(mutex) res = file.rawRead(cast(ubyte[])ctxt.buffer);
				if (res)
					ctxt.offset = cast(ulong) (ctxt.offset + res.length);

				break;

			case FileCmd.WRITE:

				File file = cast(File)ctxt.file;
				if (ctxt.offset != -1)
					file.seek(cast(long)ctxt.offset);
				synchronized(mutex) {
					file.rawWrite(cast(ubyte[])ctxt.buffer);
				}
				file.flush();
				ctxt.offset = cast(ulong) (ctxt.offset + ctxt.buffer.length);
				break;

			case FileCmd.APPEND:
				File file = cast(File)ctxt.file;
				synchronized(mutex) file.rawWrite(cast(ubyte[]) ctxt.buffer);
				ctxt.offset = cast(ulong) file.size();
				file.flush();
				break;
		} catch (Throwable e) {
			auto status = StatusInfo.init;
			status.code = Status.ERROR;
			try status.text = "Error in " ~  cmd.to!string ~ ", " ~ e.toString(); catch {}
			ctxt.status = status;
		}


		try {

			cmdInfo.ready.trigger(m_evLoop);

			synchronized(gs_wlock)
				gs_waiters.insertBack(m_waiter);
			gs_started.notifyAll(); // saves some waiting on a new thread
		}
		catch (Throwable e) {
			static if (DEBUG) {
				try writeln("AsyncFile Thread Error: ", e.toString()); catch {}
			}
			auto status = StatusInfo.init;
			status.code = Status.ERROR;
			try status.text = e.toString(); catch {}
			ctxt.status = status;
		}
	}

	void run()
	{
		core.atomic.atomicOp!"+="(gs_threadCnt, cast(int) 1);
		try {
			m_evLoop = new EventLoop;
			synchronized(gs_wlock) {
				gs_waiters.insertBack(m_waiter);
			}

			gs_started.notifyAll();

			process();
		} catch (Throwable e) {
			static if (DEBUG) {
				try writeln("Error inserting in waiters " ~ e.toString()); catch {}
			}
		}

		core.atomic.atomicOp!"-="(gs_threadCnt, cast(int) 1);
	}

	void stop()
	{
		atomicStore(g_stop, true);
		try (cast(Waiter)m_waiter).cond.notifyAll();
		catch (Exception e) {
			static if (DEBUG) {
				try writeln("Exception occured notifying foreign thread: ", e.toString()); catch {}
			}
		}
	}

	private void process() {
		while(!atomicLoad(g_stop)) {
			CommandInfo cmd;
			try synchronized(m_waiter.mtx) {
				if (!m_waiter.cond) return;
				m_waiter.cond.wait();
			}
			catch {}
			if (atomicLoad(g_stop)) break;
			try synchronized(gs_wlock) {
				if (gs_jobs.empty) continue;
				cmd = gs_jobs.back;
				gs_jobs.removeBack();
			} catch {}

			final switch (cmd.type) {
				case CmdInfoType.FILE:
					process(cast(shared AsyncFile) cmd.data);
					break;
				case CmdInfoType.DNS:
					process(cast(shared AsyncDNS) cmd.data);
					break;
			}

		}
	}

}

Waiter popWaiter() {
	if (atomicLoad(gs_threadCnt) == 0) return Waiter.init; // we're in a static ctor probably...
	Waiter cmd_handler;
	bool start_thread;
	do {
		if (start_thread) {
			Thread thr = new CmdProcessor;
			thr.isDaemon = true;
			thr.name = "CmdProcessor";
			thr.start();
			gs_threads.add(thr);
		}

		synchronized(gs_wlock) {
			if (start_thread && !gs_started.wait(5.seconds))
				continue;

			try {
				if (!cmd_handler.mtx && !gs_waiters.empty) {
					cmd_handler = gs_waiters.back;
					gs_waiters.removeBack();
				}
				else if (core.atomic.atomicLoad(gs_threadCnt) < 16) {
					start_thread = true;
				}
				else {
					Thread.sleep(50.usecs);
				}
			} catch (Exception e){
				static if (DEBUG) {
					import std.stdio : writeln;
					writeln("Exception in popWaiter: ", e);
				}
			}
		}
	} while(!cmd_handler.cond);
	return cmd_handler;
}

shared static this() {
	import std.stdio : writeln;
	gs_wlock = new Mutex;
	gs_threads = new ThreadGroup;
	gs_started = new Condition(gs_wlock);
}

bool spawnAsyncThreads() nothrow {
	import core.atomic : atomicLoad;
	try {
		if(!atomicLoad(gs_closing) && atomicLoad(gs_threadCnt) == 0) {
			synchronized {
				if(!atomicLoad(gs_closing) && atomicLoad(gs_threadCnt) == 0) {
					foreach (i; 0 .. 4) {
						Thread thr = new CmdProcessor;
						thr.isDaemon = true;
						thr.name = "CmdProcessor";
						gs_threads.add(thr);
						thr.start();
						synchronized(gs_wlock)
							gs_started.wait(1.seconds);
					}
				}
			}
		}
	} catch(Exception ignore) {
		return false;
	}
	return true;
}

void destroyAsyncThreads() {
	if (!atomicLoad(gs_closing)) atomicStore(gs_closing, true);
	else return;
	synchronized(gs_wlock) foreach (thr; gs_threads) {
		CmdProcessor thread = cast(CmdProcessor)thr;
		thread.stop();
		import core.thread : thread_isMainThread;
		if (thread_isMainThread)
			thread.join();
	}
}

static ~this() {
 import core.thread : thread_isMainThread;
                if (thread_isMainThread)
	destroyAsyncThreads();
}

shared static ~this() {
	assert(atomicLoad(gs_closing), "You must call libasync.threads.destroyAsyncThreads() upon termination of the program to avoid segfaulting");
}

enum CmdInfoType {
	FILE,
	DNS
}

struct CommandInfo {
	CmdInfoType type;
	void* data;
}
