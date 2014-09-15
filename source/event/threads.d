module event.threads;
import core.sync.mutex;
import core.sync.condition;
import core.thread;
import event.events;
import std.stdio;
import std.container : Array;

nothrow {
	
	__gshared Mutex gs_wlock;
	__gshared Array!(void*) gs_waiters; // Array!(shared AsyncSignal)
	__gshared Array!CommandInfo gs_jobs; // Array!(shared AsyncFile)
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
	shared AsyncSignal m_waiter;
	bool m_stop;
	
	this() {
		try super(&run);
		catch (Throwable e) {
			import std.stdio;
			try writeln("Failed to run thread ... ", e.toString()); catch {}
		}
	}

	void process(shared AsyncDNS ctxt) {
		auto cmdInfo = ctxt.cmdInfo;
		auto mutex = cmdInfo.mtx;
		DNSCmd cmd;
		shared AsyncSignal waiter;
		string url;
		cmd = cmdInfo.command; 
		waiter = cmdInfo.waiter;
		url = cmdInfo.url;

		import std.stdio;
		
		try writeln("Processing command: ", cmd); catch {}
		assert(m_waiter is waiter, "File processor is handling a command from the wrong thread");
		
		
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
		
		cmdInfo.ready.trigger(m_evLoop);
		
		try {
			synchronized(gs_wlock)
				gs_waiters.insertBack(cast(void*) m_waiter);
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
		shared AsyncSignal waiter;
		cmd = cmdInfo.command; 
		waiter = cmdInfo.waiter;

		import std.stdio;
		
		try writeln("Processing command: ", cmd); catch {}
		assert(m_waiter is waiter, "File processor is handling a command from the wrong thread");
		
		
		try final switch (cmd)
		{
			case FileCmd.READ:
				File file = File(ctxt.filePath.toNativeString(), "r");
				if (ctxt.offset != -1)
					file.seek(ctxt.offset);
				ubyte[] res;
				synchronized(mutex) res = file.rawRead(cast(ubyte[])ctxt.buffer);
				if (res)
					ctxt.offset = cast(size_t) (ctxt.offset + res.length);
				
				break;
				
			case FileCmd.WRITE:
				File file = File(ctxt.filePath.toNativeString(), "w");
				if (ctxt.offset != -1)
					file.seek(ctxt.offset);
				synchronized(mutex) file.rawWrite(cast(ubyte[])ctxt.buffer);
				ctxt.offset = cast(size_t) (ctxt.offset + ctxt.buffer.length);
				break;
				
			case FileCmd.APPEND:
				
				File file = File(ctxt.filePath.toNativeString(), "a");
				synchronized(mutex) file.rawWrite(cast(ubyte[]) ctxt.buffer);
				ctxt.offset = cast(size_t) file.size();
				break;
		} catch (Throwable e) {
			auto status = StatusInfo.init;
			status.code = Status.ERROR;
			try status.text = e.toString(); catch {}
			ctxt.status = status;
		}

		cmdInfo.ready.trigger(m_evLoop);
		
		try {
			synchronized(gs_wlock)
				gs_waiters.insertBack(cast(void*) m_waiter);
			gs_started.notifyAll(); // saves some waiting on a new thread
		}
		catch (Throwable e) {
			auto status = StatusInfo.init;
			status.code = Status.ERROR;
			try status.text = e.toString(); catch {}
			ctxt.status = status;
		}
	}
	
	void run()
	{
		m_evLoop = new EventLoop;
		m_waiter = new shared AsyncSignal(m_evLoop);
		m_waiter.run(&handler);
		try {
			synchronized(gs_wlock) {
				gs_waiters.insertBack(cast(void*)m_waiter);
			}
			
			gs_started.notifyAll();
		} catch {
			try writeln("Error inserting in waiters"); catch {}
		}
		
		while(m_evLoop.loop()){
			try synchronized(this) if (m_stop) break; catch {
				try writeln("Lock error?"); catch {}
			}
			continue;
		}
	}
	
	synchronized void stop()
	{
		m_stop = true;
	}
	
	private void handler() {
		while(true) {
			CommandInfo cmd;

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

shared(AsyncSignal) popWaiter() {
	shared AsyncSignal cmd_handler;
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
		thr.start();
		gs_threads.add(thr);
		synchronized(gs_wlock)
			gs_started.wait(1.seconds);
	}
	gs_threadCnt = cast(int) 4;
}

void destroyAsyncThreads() {
	foreach (thr; gs_threads) {
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