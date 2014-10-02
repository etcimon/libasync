module libasync.threads;
import core.sync.mutex;
import core.sync.condition;
import core.thread;
import libasync.events;
import std.stdio;
import std.container : Array;

nothrow {
	struct Waiter {
		Mutex mtx;
		Condition cond;
	}

	__gshared Mutex gs_wlock;
	__gshared Array!Waiter gs_waiters;
	__gshared Array!CommandInfo gs_jobs;
	__gshared Condition gs_started;
	
	__gshared Mutex gs_tlock;
	__gshared ThreadGroup gs_threads; // daemon threads
	shared(int) gs_threadCnt;
	
}

final class CmdProcessor : Thread 
{
nothrow:
private:
	EventLoop m_evLoop;
	Waiter m_waiter;
	bool m_stop;
	
	this() {
		try {
			Mutex mtx = new Mutex;
			Condition cond = new Condition(mtx);
			m_waiter = Waiter(mtx, cond);
			super(&run);
		}
		catch (Throwable e) {
			import std.stdio;
			try writeln("Failed to run thread ... ", e.toString()); catch {}
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
		import std.file : exists;
		try if (cmdInfo.create_if_not_exists || cmdInfo.truncate_if_exists) {
			bool flag;
			if (cmdInfo.create_if_not_exists && !exists(ctxt.filePath.toNativeString()))
				flag = true;
			else if (cmdInfo.truncate_if_exists && exists(ctxt.filePath.toNativeString()))
				flag = true;
			if (flag) // touch
			{	File dummy = File(ctxt.filePath.toNativeString(), "w"); }
		}
		catch (Exception e){
			auto status = StatusInfo.init;
			status.code = Status.ERROR;
			try status.text = "Could not create the file in destination: " ~ e.toString(); catch {}
			ctxt.status = status;
		}

		
		try final switch (cmd)
		{
			case FileCmd.READ:
				File file = File(ctxt.filePath.toNativeString(), "rb");
				if (ctxt.offset != -1)
					file.seek(cast(long)ctxt.offset);
				ubyte[] res;
				synchronized(mutex) res = file.rawRead(cast(ubyte[])ctxt.buffer);
				if (res)
					ctxt.offset = cast(ulong) (ctxt.offset + res.length);

				file.close();
				break;
				
			case FileCmd.WRITE:

				File file = File(ctxt.filePath.toNativeString(), "r+b");
				if (ctxt.offset != -1)
					file.seek(cast(long)ctxt.offset);
				synchronized(mutex) {
					file.rawWrite(cast(ubyte[])ctxt.buffer);
				}
				file.flush();
				ctxt.offset = cast(ulong) (ctxt.offset + ctxt.buffer.length);
				file.close();
				break;

			case FileCmd.APPEND:
				
				File file = File(ctxt.filePath.toNativeString(), "a+b");
				synchronized(mutex) file.rawWrite(cast(ubyte[]) ctxt.buffer);
				ctxt.offset = cast(ulong) file.size();
				file.close();
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
			try writeln("ERROR"); catch {}
			auto status = StatusInfo.init;
			status.code = Status.ERROR;
			try status.text = e.toString(); catch {}
			ctxt.status = status;
		}
	}
	
	void run()
	{
		m_evLoop = new EventLoop;
		try {
			synchronized(gs_wlock) {
				gs_waiters.insertBack(m_waiter);
			}
			
			gs_started.notifyAll();
		} catch {
			try writeln("Error inserting in waiters"); catch {}
		}

		process();
	}
	
	synchronized void stop()
	{
		m_stop = true;
		try (cast(Waiter)m_waiter).cond.notifyAll();
		catch (Exception e) {
			try writeln("Exception occured notifying foreign thread: ", e); catch {}
		}
	}
	
	private void process() {
		while(true) {
			CommandInfo cmd;

			try synchronized(m_waiter.mtx)
				m_waiter.cond.wait();
			catch {}

			if (m_stop)
				break;

			try synchronized(gs_wlock) {
				if (gs_jobs.empty) return;
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
	Waiter cmd_handler;
	bool start_thread;
	do {
		if (start_thread) {
			Thread thr = new CmdProcessor;
			thr.isDaemon = true;
			thr.start();
			
			core.atomic.atomicOp!"+="(gs_threadCnt, cast(int) 1);
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
				writeln("Exception in popWaiter: ", e);
			}
		}
	} while(!cmd_handler.cond);
	return cmd_handler;
}

shared static this() {
	import std.stdio : writeln;
	gs_tlock = new Mutex;
	gs_wlock = new Mutex;
	gs_threads = new ThreadGroup;
	gs_started = new Condition(gs_wlock);
	foreach (i; 0 .. 4) {
		Thread thr = new CmdProcessor;
		thr.isDaemon = true;
		thr.name = "CmdProcessor";
		thr.start();
		gs_threads.add(thr);
		synchronized(gs_wlock)
			gs_started.wait(1.seconds);
	}
	gs_threadCnt = cast(int) 4;
}

void destroyAsyncThreads() {
	synchronized(gs_tlock) foreach (thr; gs_threads) {
		CmdProcessor thread = cast(CmdProcessor)thr;
		(cast(shared)thread).stop();
	}
}

enum CmdInfoType {
	FILE,
	DNS
}

struct CommandInfo {
	CmdInfoType type;
	void* data;
}