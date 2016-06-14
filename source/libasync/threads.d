
module libasync.threads;

import std.parallelism;

import libasync.internals.logging;

bool spawnAsyncThreads(uint threadCount = totalCPUs > 1 ? totalCPUs - 1 : 1) nothrow
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
bool doOffThread(void delegate() work) {
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