
module libasync.threads;

import std.parallelism;

import libasync.internals.logging;

version (Posix):

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
	void doAsync(void delegate() work)  {
		task(work);
	}

	nothrow
	void destroyAsyncThreads() {
		try taskPool.finish(true);
		catch (Exception e) {
			critical("Failed to terminate worker threads: ", e.toString());
			assert(false);
		}
	}