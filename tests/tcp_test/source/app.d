import libasync;
import std.socket;
import std.stdio;
import core.memory;
import memutils.utils;

void main() {
	void handler(TCPEvent ev) {
		writeln("Event ", ev);
	}

	auto evl = ThreadMem.alloc!EventLoop();
	auto count = 1000;
	foreach(_;0 .. count) {
		auto conn = ThreadMem.alloc!AsyncTCPConnection(evl);
		conn.host("1.1.1.1", 9999).run(&handler);
		auto timer = ThreadMem.alloc!AsyncTimer(evl);
		timer.duration = 10.msecs;
		timer.run({
				writeln("timeout");
				try conn.kill(true); catch (Throwable e) { }
				timer.kill();
			});
		evl.loop(100.seconds);
		writeln("loop done");
		ThreadMem.free(conn);
		ThreadMem.free(timer);
		GC.collect();
		GC.minimize();
	}
	writeln("done");
	destroyAsyncThreads();
}
