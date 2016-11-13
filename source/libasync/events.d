///
module libasync.events;

import std.stdio;

import core.thread;
import std.container : Array;
import std.datetime : Duration;
import std.typecons : Flag;
import libasync.internals.memory : FreeListObjectAlloc;

public import libasync.types;
public import libasync.bufferedtcp;
public import libasync.tcp;
public import libasync.udp;
public import libasync.uds;
public import libasync.notifier;
public import libasync.dns;
public import libasync.timer;
public import libasync.signal;
public import libasync.watcher;
public import libasync.file;
public import libasync.threads;
public import libasync.event;
public import libasync.socket;

version(Windows) {
	public import libasync.windows;
}

version(Posix) {
	public import libasync.posix;
}

///
EventLoop getThreadEventLoop() nothrow {
	static EventLoop evLoop;
	if (!evLoop)  {
		evLoop = new EventLoop;
	}
	return evLoop;
}

/// Event handlers can be registered to the event loop by being run(), all events
/// associated with them will trigger the OS to resume the underlying thread which
/// enables the existence of all the asynchroneous event objects in this library.
final class EventLoop
{

package:
	EventLoopImpl m_evLoop;
	bool m_asyncThreadsStarted = false;

nothrow:
public:
	///
	this() {
		if (m_evLoop.started || !m_evLoop.init(this))
			assert(false, "Event loop initialization failure");
	}

	/// Call this to cleanup underlying OS resources. The implementation is currently incomplete
	/// and requires the process to be shut down for the resources to be collected automatically.
	/// Used as a placeholder in the meantime.
	void exit() {
		m_evLoop.exit();
	}

	///
	NetworkAddress resolveIP(in string ip, ushort port = 0, isIPv6 ipv6 = isIPv6.no, isTCP tcp = isTCP.yes, isForced force = isForced.yes)
	{
		if (!force)
			return m_evLoop.getAddressFromIP(ip, port, ipv6, tcp);
		NetworkAddress addr = m_evLoop.getAddressFromIP(ip, port, ipv6, tcp);
		if (status.code != Status.OK)
			addr = m_evLoop.getAddressFromIP(ip, port, !ipv6, tcp);
		return addr;
	}

	/** Blocks until the hostname is resolved, unless it's invalid. */
	NetworkAddress resolveHost(in string host, ushort port = 0, isIPv6 ipv6 = isIPv6.no, isTCP tcp = isTCP.yes, isForced force = isForced.yes)
	{
		if (!force)
			return m_evLoop.getAddressFromDNS(host, port, ipv6, tcp);
		NetworkAddress addr = m_evLoop.getAddressFromDNS(host, port, ipv6, tcp);
		if (status.code != Status.OK)
			addr = m_evLoop.getAddressFromDNS(host, port, !ipv6, tcp);
		return addr;
	}

package:

	@property StatusInfo status() const
	{
		return m_evLoop.status;
	}

	@property string error() const
	{
		return m_evLoop.error;
	}

	uint recvFrom(in fd_t fd, ubyte[] data, ref NetworkAddress addr) {
		return m_evLoop.recvFrom(fd, data, addr);
	}

	uint sendTo(in fd_t fd, in ubyte[] data, in NetworkAddress addr) {
		return m_evLoop.sendTo(fd, data, addr);
	}

	uint recv(in fd_t fd, ubyte[] data)
	{
		return m_evLoop.recv(fd, data);
	}

	pragma(inline, true)
	uint send(in fd_t fd, in ubyte[] data)
	{
		return m_evLoop.send(fd, data);
	}

	pragma(inline, true)
	uint read(in fd_t fd, ref ubyte[] data)
	{
		return m_evLoop.read(fd, data);
	}

	uint readChanges(in fd_t fd, ref DWChangeInfo[] dst) {
		return m_evLoop.readChanges(fd, dst);
	}

	uint write(in fd_t fd, in ubyte[] data)
	{
		return m_evLoop.write(fd, data);
	}

	uint watch(in fd_t fd, in WatchInfo info) {
		return m_evLoop.watch(fd, info);
	}

	bool unwatch(in fd_t fd, in fd_t wd) {
		return m_evLoop.unwatch(fd, wd);
	}

	bool broadcast(in fd_t fd, bool b)
	{
		return m_evLoop.broadcast(fd, b);
	}

	NetworkAddress localAddr(in fd_t fd, bool ipv6 = false) {
		return m_evLoop.localAddr(fd, ipv6);
	}

	bool notify(T)(in fd_t fd, T payload)
		if (is(T == shared AsyncSignal) || is(T == AsyncNotifier))
	{
		return m_evLoop.notify(fd, payload);
	}

	bool setOption(T)(in fd_t fd, TCPOption option, in T val) {
		return m_evLoop.setOption(fd, option, val);
	}

	/*uint send(in ubyte[] data, in fd_t fd, in NetworkAddress dst)
	{
		return m_evLoop.send(data, fd, dst);
	}*/

	bool closeSocket(fd_t fd, bool connected, bool listener = false)
	{
		return m_evLoop.closeSocket(fd, connected, listener);
	}

	bool run(AsyncEvent ctxt, EventHandler del) {
		return m_evLoop.run(ctxt, del);
	}

	fd_t run(AsyncTCPConnection ctxt, TCPEventHandler del) {
		return m_evLoop.run(ctxt, del);
	}

	fd_t run(AsyncTCPListener ctxt, TCPAcceptHandler del) {
		return m_evLoop.run(ctxt, del);
	}

	version (Posix)
	fd_t run(AsyncUDSConnection ctxt) {
		return m_evLoop.run(ctxt);
	}

	version (Posix)
	fd_t run(AsyncUDSListener ctxt) {
		return m_evLoop.run(ctxt);
	}

	fd_t run(AsyncSocket ctxt) {
		return m_evLoop.run(ctxt);
	}

	void submitRequest(AsyncAcceptRequest* ctxt) {
		m_evLoop.submitRequest(ctxt);
	}

	void submitRequest(AsyncReceiveRequest* ctxt) {
		m_evLoop.submitRequest(ctxt);
	}

	void submitRequest(AsyncSendRequest* ctxt) {
		m_evLoop.submitRequest(ctxt);
	}

	import libasync.internals.socket_compat : sockaddr, socklen_t;
	bool bind(AsyncSocket ctxt, sockaddr* addr, socklen_t addrlen)
	{
		return m_evLoop.bind(ctxt, addr, addrlen);
	}

	bool connect(AsyncSocket ctxt, sockaddr* addr, socklen_t addrlen)
	{
		return m_evLoop.connect(ctxt, addr, addrlen);
	}

	bool listen(AsyncSocket ctxt, int backlog)
	{
		return m_evLoop.listen(ctxt, backlog);
	}

	fd_t run(shared AsyncSignal ctxt) {
		return m_evLoop.run(ctxt);
	}

	fd_t run(AsyncNotifier ctxt) {
		return m_evLoop.run(ctxt);
	}

	fd_t run(AsyncTimer ctxt, TimerHandler del, Duration timeout) {
		return m_evLoop.run(ctxt, del, timeout);
	}

	fd_t run(AsyncUDPSocket ctxt, UDPHandler del) {
		return m_evLoop.run(ctxt, del);
	}

	fd_t run(AsyncDirectoryWatcher ctxt, DWHandler del) {
		return m_evLoop.run(ctxt, del);
	}

	version (Posix)
	AsyncUDSConnection accept(AsyncUDSListener ctxt) {
		return m_evLoop.accept(ctxt);
	}

	bool kill(AsyncEvent obj, bool forced = true) {
		return m_evLoop.kill(obj, forced);
	}

	bool kill(AsyncDirectoryWatcher obj) {
		return m_evLoop.kill(obj);
	}

	bool kill(AsyncSocket obj, bool forced = false) {
		return m_evLoop.kill(obj, forced);
	}

	bool kill(AsyncTCPConnection obj, bool forced = false) {
		return m_evLoop.kill(obj, forced);
	}

	bool kill(AsyncTCPListener obj) {
		return m_evLoop.kill(obj);
	}

	bool kill(shared AsyncSignal obj) {
		return m_evLoop.kill(obj);
	}

	bool kill(AsyncNotifier obj) {
		return m_evLoop.kill(obj);
	}

	bool kill(AsyncTimer obj) {
		return m_evLoop.kill(obj);
	}

	bool kill(AsyncUDPSocket obj) {
		return m_evLoop.kill(obj);
	}

	/**
		Runs the event loop once and returns false if a an unrecoverable error occured
		Using a value of 0 will return immediately, while a value of -1.seconds will block indefinitely
	*/
	public bool loop(Duration max_timeout = 100.msecs)
	{
		if(!m_asyncThreadsStarted) {
			if(!spawnAsyncThreads()) {
				return false;
			}
			m_asyncThreadsStarted = true;
		}

		if (!m_evLoop.loop(max_timeout) && m_evLoop.status.code == Status.EVLOOP_FAILURE) {
			return false;
		}

		return true;
	}

}
