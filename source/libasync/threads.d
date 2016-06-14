
module libasync.threads;

import std.parallelism;

import libasync.internals.logging;

version (Posix) {
public:

	bool spawnAsyncThreads(uint threadCount = totalCPUs) nothrow
	in {
		assert(threadCount >= 1, "Need at least one worker thread");
	} body {
		try defaultPoolThreads(threadCount);
		catch (Exception e) {
			critical("Failed to spawn worker threads: ", e.toString());
			return false;
		}
		return true;
	}

	nothrow
	bool doAsync(void delegate() work)  {
		try taskPool.put(task(work));
		catch (Exception e) {
			critical("Failed to dispatch task to thread pool: ", e.toString());
			return false;
		}
		return true;
	}

	nothrow
	void destroyAsyncThreads() {
		try taskPool.finish(true);
		catch (Exception e) {
			critical("Failed to terminate worker threads: ", e.toString());
			assert(false);
		}
	}