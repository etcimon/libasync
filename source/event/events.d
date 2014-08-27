module event.events;

import std.stdio;

import core.thread;
import std.exception;
import std.container : Array;
import std.datetime : Duration;
import std.typecons : Flag;
import event.memory : FreeListObjectAlloc;

public import event.types;
public import event.tcp;
public import event.udp;
public import event.notifier;
public import event.dns;
public import event.timer;
public import event.signal;
public import event.filesystem;

version(Windows) {
	public import event.windows;
}

version(Posix) {
	public import event.posix;
}

final class EventLoop
{

package:
	EventLoopImpl m_evLoop;

nothrow:
public:
	this() { 

		if (m_evLoop.started || !m_evLoop.init(this))
			assert(false, "Event loop initialization failure");
	}

	void exit() {
		m_evLoop.exit();
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

	uint recvFrom(in fd_t fd, ref ubyte[] data, ref NetworkAddress addr) {
		return m_evLoop.recvFrom(fd, data, addr);
	}

	uint sendTo(in fd_t fd, in ubyte[] data, in NetworkAddress addr) {
		return m_evLoop.sendTo(fd, data, addr);
	}

	uint recv(in fd_t fd, ref ubyte[] data)
	{
		return m_evLoop.recv(fd, data);
	}

	/*uint recv(out ubyte[] data, in fd_t fd, in NetworkAddress dst)
	{
		return m_evLoop.recv(data, fd, dst);
	}*/
	
	uint send(in fd_t fd, in ubyte[] data)
	{
		return m_evLoop.send(fd, data);
	}
	
	uint read(in fd_t fd, ref ubyte[] data)
	{
		return m_evLoop.read(fd, data);
	}

	uint write(in fd_t fd, in ubyte[] data)
	{
		return m_evLoop.write(fd, data);
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

	/* Returns a structure representing the peer address from an IP or a Hostname
	 * It is much slower to use a hostname because of the blocking dns resolver.
	 * An AsyncDNS can be used to retrieve this and improve performance-critical code.
	*/
	NetworkAddress resolveAny(string host, ushort port)
	in { assert(host !is null); }
	body {
		import event.validator;
		import std.typecons : Flag;

		NetworkAddress addr;
		try {
			if ( validateHost(host) )
				addr = resolveIP(host, port, isIPv6.no, isTCP.yes, isForced.no);
			else if ( validateHost(host) ) // this validation is faster than IPv6
				addr = resolveHost(host, port, isIPv6.no, isTCP.yes, isForced.yes);
			else if ( validateIPv6(host) )
				addr = resolveIP(host, port, isIPv6.yes, isTCP.yes, isForced.no);
			else {
				m_evLoop.setInternalError!"AsyncTCP.resolver(invalid_host)"(Status.ERROR);
				return NetworkAddress.init;
			}
		} catch (Exception e) {
			m_evLoop.setInternalError!"AsyncTCP.resolver"(Status.ERROR, e.msg);
			return NetworkAddress.init;
		}
		return addr;
	}

	NetworkAddress resolveIP(in string ip, ushort port = 0, isIPv6 ipv6 = isIPv6.no, isTCP tcp = isTCP.yes, isForced force = isForced.yes)
	{
		if (!force)
			return m_evLoop.getAddressFromIP(ip, port, ipv6, tcp);
		NetworkAddress addr = m_evLoop.getAddressFromIP(ip, port, ipv6, tcp);
		if (status.code != Status.OK)
			addr = m_evLoop.getAddressFromIP(ip, port, !ipv6, tcp);
		return addr;
	}

	/* Blocks until the hostname is resolved, unless it's invalid. */
	NetworkAddress resolveHost(in string ip, ushort port = 0, isIPv6 ipv6 = isIPv6.no, isTCP tcp = isTCP.yes, isForced force = isForced.yes)
	{
		if (!force)
			return m_evLoop.getAddressFromDNS(ip, port, ipv6, tcp);
		NetworkAddress addr = m_evLoop.getAddressFromDNS(ip, port, ipv6, tcp);
		if (status.code != Status.OK)
			addr = m_evLoop.getAddressFromDNS(ip, port, !ipv6, tcp);
		return addr;
	}

	bool closeSocket(fd_t fd, bool connected, bool listener = false)
	{
		return m_evLoop.closeSocket(fd, connected, listener);
	}

	fd_t run(AsyncTCPConnection ctxt, TCPEventHandler del) {
		return m_evLoop.run(ctxt, del);
	}

	fd_t run(AsyncTCPListener ctxt, TCPAcceptHandler del) {
		return m_evLoop.run(ctxt, del);
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
	*/
	bool loop(Duration max_timeout = 1.seconds)
	{
		if (!m_evLoop.loop(max_timeout) && m_evLoop.status.code == Status.EVLOOP_FAILURE)
			return false;

		return true;
	}
	
}
