import libasync;
import libasync.watcher;
import std.stdio : writeln;
import libasync.threads;

// You must deinitialize the worker thread manually when the application closes
shared static ~this() { destroyAsyncThreads(); }

// This is our main callback, it gets called when there are changes.
void onDirectoryEvent(DWChangeInfo change) {
	writeln("Main Callback got directory event: ", change);
}

// Program entry point
void main()
{
	// Each thread has one event loop. It does not run unless we run it with `loop` in a loop.
	auto ev_loop = getThreadEventLoop();

	// We can initialize an async object by attaching it to this event loop
	auto watcher = new AsyncDirectoryWatcher(ev_loop);

	DWChangeInfo[8] change_buf;

	// By `run`ing the async object, we register it in the operating system
	watcher.run(
		{ // This scope is executed at each directory event
			writeln("Enter Handler (directory event captured)");
			// We will have to drain the internal event buffer first
			DWChangeInfo[] changes = change_buf[];
			uint cnt;
			// Capture the directory events up to 8 at a time
	        do {
				cnt = watcher.readChanges(changes);
				// Forward them to our custom handler
				foreach (i; 0 .. cnt) {
					onDirectoryEvent(changes[i]);
				}
			} while (cnt > 0);
	});

	// This makes our watcher look for file changes in the "temp" sub folder, it must be used after the watcher is registered (aka `run`). It is relative to the current directory which is usually this running executable's folder
	watcher.watchDir("temp");
	writeln("Event loop now running. Try saving a file in the temp/ folder!");

	while (ev_loop.loop())
		continue;
	writeln("Event loop exited");

}
