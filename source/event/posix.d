module event.posix;

version (Posix):

import event.types;
import std.string : toStringz;
import std.conv : to;
import std.datetime : Duration, msecs, seconds;
import std.traits : isIntegral;
import std.typecons : Tuple, tuple;
import core.stdc.errno;
import event.events;
import event.memory : FreeListObjectAlloc;
enum SOCKET_ERROR = -1;
version(linux) enum RT_USER_SIGNAL = 34;
alias fd_t = int;

version(linux) {
	import event.epoll;
	const EPOLL = true;
}
version(OSX) {
	import event.kqueue;
	const EPOLL = false;
}
version(FreeBSD) {
	import event.kqueue;
	const EPOLL = false;
}
package struct EventLoopImpl {
	static if (EPOLL) {
		pragma(msg, "Using Linux EPOLL for events");
	}
	else /* if KQUEUE */
	{
		pragma(msg, "Using FreeBSD KQueue for events");
	}

package:
	alias error_t = EPosix;

nothrow:
private:

	/// members
	EventLoop m_evLoop;
	ushort m_instanceId;
	bool m_started;
	StatusInfo m_status;
	error_t m_error = EPosix.EOK;
	EventInfo* m_evSignal;
	static if (EPOLL){
		fd_t m_epollfd;
	}
	else /* if KQUEUE */
	{
		fd_t m_kqueuefd;
	}
package:


	@property bool started() const {
		return m_started;
	}
	
	bool init(EventLoop evl)
	in { assert(!m_started); }
	body
	{

		import core.atomic;
		shared static ushort i;
		m_instanceId = i;
		static if (!EPOLL) g_threadId = new size_t(cast(size_t)m_instanceId);

		core.atomic.atomicOp!"+="(i, cast(ushort) 1);
		m_evLoop = evl;

		import core.thread;
		try Thread.getThis().priority = Thread.PRIORITY_MAX;
		catch (Exception e) { assert(false, "Could not set thread priority"); }

		static if (EPOLL)
		{

			m_epollfd = epoll_create1(0);

			if (catchError!"epoll_create1"(m_epollfd))
				return false;
				
			import core.sys.linux.sys.signalfd;
			import core.sys.posix.signal;
			import core.thread : getpid;

			fd_t err;
			fd_t sfd;

			sigset_t mask;

			try {
				foreach (j; 0 .. 32) {
					sigemptyset(&mask);
					sigaddset(&mask, RT_USER_SIGNAL + m_instanceId + j);
					err = pthread_sigmask(SIG_BLOCK, &mask, null);
					if (catchError!"sigprocmask"(err))
					{
						return false;
					}
				}
				sigemptyset(&mask);
				sigaddset(&mask, RT_USER_SIGNAL + m_instanceId);

				err = pthread_sigmask(SIG_BLOCK, &mask, null);
				if (catchError!"sigprocmask"(err))
				{
					return false;
				}
			} catch { }



			sfd = signalfd(-1, &mask, SFD_NONBLOCK);
			assert(sfd > 0, "Failed to setup signalfd in epoll");

			EventType evtype;

			epoll_event _event;
			_event.events = EPOLLIN;
			evtype = EventType.Signal;
			try 
				m_evSignal = FreeListObjectAlloc!EventInfo.alloc(sfd, evtype, EventObject.init, m_instanceId);
			catch (Exception e){ 
				assert(false, "Allocation error"); 
			}
			_event.data.ptr = cast(void*) m_evSignal;

			err = epoll_ctl(m_epollfd, EPOLL_CTL_ADD, sfd, &_event);
			if (catchError!"EPOLL_CTL_ADD(sfd)"(err))
			{
				return false;
			}

		}
		else /* if KQUEUE */ 
		{
			import event.kqueue : kqueue;
			m_kqueuefd = kqueue();
			import event.kqueue;
			import core.sys.posix.signal;
			int err;
			try {
				sigset_t mask;
				sigemptyset(&mask);
				sigaddset(&mask, SIGUSR1);
				
				err = sigprocmask(SIG_BLOCK, &mask, null);
			} catch {}

			import event.kqueue;
			EventType evtype = EventType.Signal;

			// use GC because FreeListObjectAlloc fails at emplace for shared objects
			try 
				m_evSignal = FreeListObjectAlloc!EventInfo.alloc(SIGUSR1, evtype, EventObject.init, m_instanceId);
			catch (Exception e) {
				assert(false, "Failed to allocate resources");
			}

			if (catchError!"siprocmask"(err))
				return 0;

			kevent_t _event;
			EV_SET(&_event, SIGUSR1, EVFILT_SIGNAL, EV_ADD | EV_ENABLE, 0, 0, m_evSignal);
			err = kevent(m_kqueuefd, &_event, 1, null, 0, null);
			if (catchError!"kevent_add(SIGUSR1)"(err))
				assert(false, "Add SIGUSR1 failed at kevent call");
		}

		log("init");

		return true;
	}

	void exit() {
		import core.sys.posix.unistd : close;
		static if (EPOLL) {
			close(m_epollfd);

			try FreeListObjectAlloc!EventInfo.free(m_evSignal);
			catch (Exception e) { assert(false, "Failed to free resources"); }

		}
		else
			close(m_kqueuefd);
	}

	@property const(StatusInfo) status() const {
		return m_status;
	}

	@property string error() const {
		string* ptr;
		return ((ptr = (m_error in EPosixMessages)) !is null) ? *ptr : string.init;
	}

	bool loop(Duration timeout = 0.seconds)
	in { assert(Fiber.getThis() is null); }
	body {

		import event.memory;
		bool success = true;
		int num;

		static if (EPOLL) {

			static align(1) epoll_event[] events;
			if (events is null)
			{
				try events = new epoll_event[128];
				catch (Exception e) {
					assert(false, "Could not allocate events array: " ~ e.msg);
				}
			}
			int timeout_ms;
			if (timeout == 0.seconds)
				timeout_ms = -1;
			else timeout_ms = cast(int)timeout.total!"msecs";

			/// Retrieve pending events
			num = epoll_wait(m_epollfd, cast(epoll_event*)events.ptr, 128, timeout_ms);

			assert(events !is null && events.length <= 128);

			
		}
		else /* if KQUEUE */ {
			import event.kqueue;
			import core.sys.posix.time : time_t;
			import core.sys.posix.config : c_long;
			static kevent_t[] events;
			if (events.length == 0) {
				try events = allocArray!kevent_t(manualAllocator(), 128); 
				catch (Exception e) { assert(false, "Could not allocate events array"); }				
			}
			time_t secs = timeout.split!("seconds", "nsecs")().seconds;
			c_long ns = timeout.split!("seconds", "nsecs")().nsecs;
			timespec tspec = timespec(secs, ns);

			num = kevent(m_kqueuefd, null, 0, cast(kevent_t*) events, cast(int) events.length, &tspec);

		}

		auto errors = [	tuple(EINTR, Status.EVLOOP_TIMEOUT) ];
		
		if (catchEvLoopErrors!"event_poll'ing"(num, errors)) 
			return false;

		log("Got " ~ num.to!string ~ " event(s)");

		foreach(i; 0 .. num) {
			success = false;
			m_status = StatusInfo.init;
			static if (EPOLL) 
			{
				epoll_event _event = events[i];
				try log("Event " ~ i.to!string ~ " of: " ~ events.length.to!string); catch {}
			}
			else /* if KQUEUE */
			{
				kevent_t _event = events[i];
			}


			static if (EPOLL) {
				// prevent some issues with loopback...
				if (_event.events == 0 || _event.events & EPOLLWRBAND || _event.events & EPOLLRDBAND) {
					assert(false, "loopback error");
				}
				EventInfo* info = cast(EventInfo*) _event.data.ptr;
				int event_flags = cast(int) _event.events;

			}
			else /* if KQUEUE */
			{
				EventInfo* info = cast(EventInfo*) _event.udata;
				int event_flags = (event.filter << 16) | (_event.flags & 0xffff);
			}

			assert(info.owner == m_instanceId, "Event " ~ (cast(int)(info.evType)).to!string ~ " is invalid: supposidly created in instance #" ~ info.owner.to!string ~ ", received in " ~ m_instanceId.to!string ~ " event: " ~ event_flags.to!string);
				
			final switch (info.evType) {
				case EventType.TCPAccept:
					if (info.fd == 0)
						break;
					success = onTCPAccept(info.fd, info.evObj.tcpAcceptHandler, event_flags);
					break;
				case EventType.Notifier:

					try log("Got notifier!"); catch {}
					try info.evObj.notifierHandler();
					catch (Exception e) {
						setInternalError!"signalEvHandler"(Status.ERROR);
					}
					break;

				case EventType.Timer:
					try log("Got timer!"); catch {}
					static if (EPOLL) {
						static long val;
						import core.sys.posix.unistd : read;
						read(info.evObj.timerHandler.ctxt.id, &val, long.sizeof);
					}
					try info.evObj.timerHandler();
					catch (Exception e) {
						setInternalError!"signalEvHandler"(Status.ERROR);
					}
					break;

				case EventType.Signal:
					try log("Got signal!"); catch {}
					static AsyncSignal[] sigarr;

					if (sigarr.length == 0) {
						try sigarr = new AsyncSignal[32]; 
						catch (Exception e) { assert(false, "Could not allocate signals array"); }		
					}

					static if (EPOLL) {
						
						try log("Got signal: " ~ info.fd.to!string ~ " of type: " ~ info.evType.to!string); catch {}
						import core.sys.linux.sys.signalfd : signalfd_siginfo;
						import core.sys.posix.unistd : read;
						signalfd_siginfo fdsi;
						fd_t err = cast(fd_t)read(info.fd, &fdsi, fdsi.sizeof);
						shared AsyncSignal sig = cast(shared AsyncSignal) cast(void*) fdsi.ssi_ptr;

						try sig.handler();
						catch (Exception e) {
							setInternalError!"signal handler"(Status.ERROR);
						}


					}
					else /* if KQUEUE */
					{
						bool more = popSignals(sigarr);
						foreach (AsyncSignal sig; sigarr)
						{
							shared AsyncSignal ptr = cast(shared AsyncSignal) sig;
							if (ptr is null)
								break;
							try (cast(shared AsyncSignal)sig).handler();
							catch (Exception e) {
								setInternalError!"signal handler"(Status.ERROR);
							}
						}
					}
					break;

				case EventType.UDPSocket:
					import core.sys.posix.unistd : close;
					success = onUDPTraffic(info.fd, info.evObj.udpHandler, event_flags);

					nothrow void abortHandler(bool graceful) {

						if (graceful) {
							try info.evObj.udpHandler(UDPEvent.CLOSE);
							catch (Exception e) { }
							close(info.fd);
							info.evObj.udpHandler.conn.socket = 0;
						}
						else {
							close(info.fd);
							info.evObj.udpHandler.conn.socket = 0;
							try info.evObj.udpHandler(UDPEvent.ERROR);
							catch (Exception e) { }
						}
						try FreeListObjectAlloc!EventInfo.free(info);
						catch (Exception e){ assert(false, "Error freeing resources"); }
					}
					
					if (!success && m_status.code == Status.ABORT) {
						abortHandler(true);
						
					}
					else if (!success && m_status.code == Status.ERROR) {
						abortHandler(false); 
					}
					break;
				case EventType.TCPTraffic:
					assert(info.evObj.tcpEvHandler.conn !is null, "TCP Connection invalid");

					success = onTCPTraffic(info.fd, info.evObj.tcpEvHandler, event_flags, info.evObj.tcpEvHandler.conn.connected, info.evObj.tcpEvHandler.conn.disconnecting);

					nothrow void abortTCPHandler(bool graceful) {

						nothrow void closeAll() {
							try log("closeAll()"); catch {}
							if (*info.evObj.tcpEvHandler.conn.connected)
								closeSocket(info.fd, true, true);
							
							info.evObj.tcpEvHandler.conn.socket = 0;
						}

						/// Close the connection after an unexpected socket error
						if (graceful) {
							try info.evObj.tcpEvHandler(TCPEvent.CLOSE);
							catch (Exception e) { }
							closeAll();
						}

						/// Kill the connection after an internal error
						else {
							closeAll();
							try info.evObj.tcpEvHandler(TCPEvent.ERROR);
							catch (Exception e) { }
						}

						if (info.evObj.tcpEvHandler.conn.inbound) {
							log("Freeing inbound connection FD#" ~ info.fd.to!string);
							try FreeListObjectAlloc!AsyncTCPConnection.free(info.evObj.tcpEvHandler.conn);
							catch (Exception e){ assert(false, "Error freeing resources"); }
						}
						try FreeListObjectAlloc!EventInfo.free(info);
						catch (Exception e){ assert(false, "Error freeing resources"); }
					}

					if (!success && m_status.code == Status.ABORT) {
						abortTCPHandler(true);
					}
					else if (!success && m_status.code == Status.ERROR) {
						abortTCPHandler(false);
					}

					break;
			}

		}
		return success;
	}

	fd_t run(AsyncTCPConnection ctxt, TCPEventHandler del)
	in { assert(ctxt.socket == fd_t.init, "TCP Connection is active. Use another instance."); }
	body {
		m_status = StatusInfo.init;
		import core.sys.posix.sys.socket : socket, SOCK_STREAM;
		import core.sys.posix.unistd : close;

		/*static if (!EPOLL) {
			gs_mutex.lock_nothrow();
			scope(exit) gs_mutex.unlock_nothrow();
		}*/

		fd_t fd = socket(cast(int)ctxt.peer.family, SOCK_STREAM, 0);

		if (catchError!("run AsyncTCPConnection")(fd)) 
			return 0;

		/// Make sure the socket doesn't block on recv/send
		if (!setNonBlock(fd)) {
			close(fd);
			return 0;
		}

		/// Enable Nagel's algorithm if specified
		if (ctxt.noDelay) {
			if (!setOption(fd, TCPOption.NODELAY, true)) {
				try log("Closing connection"); catch {}
				close(fd);
				return 0;
			}
		}

		/// Trigger the connection setup instructions
		if (!initTCPConnection(fd, ctxt, del)) {
			close(fd);
			return 0;
		}
		/*
		static if (!EPOLL) {
			gs_fdPool.insert(fd);
		}*/
		return fd;
		
	}
	
	fd_t run(AsyncTCPListener ctxt, TCPAcceptHandler del)
	in { 
		assert(ctxt.socket == fd_t.init, "TCP Listener already bound. Please run another instance."); 
		assert(ctxt.local.addr !is typeof(ctxt.local.addr).init, "No locally binding address specified. Use AsyncTCPListener.local = EventLoop.resolve*"); 
	}
	body {
		m_status = StatusInfo.init;
		import core.sys.posix.sys.socket : socket, SOCK_STREAM, socklen_t, setsockopt, SOL_SOCKET, SO_REUSEADDR;
		import core.sys.posix.unistd : close;
		/*static if (!EPOLL) {
			gs_mutex.lock_nothrow();
			scope(exit) gs_mutex.unlock_nothrow();
		}*/
		/// Create the listening socket
		fd_t fd = socket(cast(int)ctxt.local.family, SOCK_STREAM, 0);

		if (catchError!("run AsyncTCPAccept")(fd))
			return 0;

		/// Make sure the socket returns instantly when calling listen()
		if (!setNonBlock(fd)) {
			close(fd);
			return 0;
		}

		/// Allow multiple threads to listen on this address
		{ 
			int err;
			int val = 1;
			socklen_t len = val.sizeof;
			err = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &val, len);
			if (catchError!"SO_REUSEADDR"(err)) {
				close(fd);
				return 0;
			}

		}

		// todo: defer accept

		/// Automatically starts connections with noDelay if specified
		if (ctxt.noDelay) {
			if (!setOption(fd, TCPOption.NODELAY, true)) {
				try log("Closing connection"); catch {}
				close(fd);
				return 0;
			}
		}

		/// Setup the listening mechanism
		if (!initTCPListener(fd, ctxt, del)) {
			close(fd);
			return 0;
		}
		/*
		static if (!EPOLL) {
			gs_fdPool.insert(fd);
		}
*/
		return fd;
		
	}

	fd_t run(AsyncUDPSocket ctxt, UDPHandler del) {
		m_status = StatusInfo.init;

		import core.sys.posix.sys.socket;
		import std.c.linux.socket;
		import core.sys.posix.unistd;
		fd_t fd = socket(cast(int)ctxt.local.family, SOCK_DGRAM, IPPROTO_UDP);

		if (catchSocketError!("run AsyncUDPSocket")(fd))
			return 0;

		if (!setNonBlock(fd))
			return 0;

		if (!initUDPSocket(fd, ctxt, del))
			return 0;
		
		try log("UDP Socket started FD#" ~ fd.to!string);
		catch{}
		/*
		static if (!EPOLL) {
			gs_fdPool.insert(fd);
		}*/

		return fd;
	}

	fd_t run(AsyncNotifier ctxt)
	{

		m_status = StatusInfo.init;

		fd_t err;
		static if (EPOLL) {
			fd_t fd = eventfd(0, EFD_NONBLOCK);

			if (catchSocketError!("run AsyncNotifier")(fd))
				return 0;

			epoll_event _event;
			_event.events = EPOLLIN | EPOLLET;
		}	
		else /* if KQUEUE */
		{
			kevent_t _event;
			fd_t fd = cast(fd_t)createIndex();
		}
		EventType evtype = EventType.Notifier;
		NotifierHandler evh;
		evh.ctxt = ctxt;
		
		evh.fct = (AsyncNotifier ctxt) {
			try {
				ctxt.handler();
			} catch (Exception e) {
				//setInternalError!"AsyncTimer handler"(Status.ERROR);
			}
		};
		
		EventObject eobj;
		eobj.notifierHandler = evh;
		
		EventInfo* evinfo;
		
		if (!ctxt.evInfo) {
			try evinfo = FreeListObjectAlloc!EventInfo.alloc(fd, evtype, eobj, m_instanceId);
			catch (Exception e) {
				assert(false, "Failed to allocate resources: " ~ e.msg);
			}
			
			ctxt.evInfo = evinfo;
		}

		static if (EPOLL) {
			_event.data.ptr = cast(void*) evinfo;
			
			err = epoll_ctl(m_epollfd, EPOLL_CTL_ADD, fd, &_event);
			if (catchSocketError!("epoll_add(eventfd)")(err))
				return fd_t.init;
		}
		else /* if KQUEUE */
		{
			EV_SET(&_event, fd, EVFILT_USER, EV_ADD | EV_CLEAR, NOTE_FFCOPY, 0, evinfo);

			err = kevent(m_kqueuefd, &_event, 1, null, 0, null);
			
			if (catchError!"kevent_addSignal"(err))
				return fd_t.init;
		}

		return fd;


	}

	fd_t run(shared AsyncSignal ctxt) 
	{
		static if (EPOLL) {

			m_status = StatusInfo.init;

			ctxt.evInfo = cast(shared) m_evSignal;

			return cast(fd_t) (RT_USER_SIGNAL + m_instanceId);
		}
		else
		{
			m_status = StatusInfo.init;
			
			ctxt.evInfo = cast(shared) m_evSignal;
			return cast(fd_t) createIndex(ctxt);

		}
	}
	
	fd_t run(AsyncTimer ctxt, TimerHandler del, Duration timeout) {
		m_status = StatusInfo.init;

		static if (EPOLL)
		{
			import core.sys.posix.time;

			fd_t fd;
			itimerspec its;
			
			its.it_value.tv_sec = timeout.split!("seconds", "nsecs")().seconds;
			its.it_value.tv_nsec = timeout.split!("seconds", "nsecs")().nsecs;
			if (!ctxt.oneShot)
			{
				its.it_interval.tv_sec = its.it_value.tv_sec;
				its.it_interval.tv_nsec = its.it_value.tv_nsec;
			}
			import std.stdio;
			if (ctxt.id == fd_t.init) {

				fd = timerfd_create(CLOCK_REALTIME, 0);
				if (catchError!"timer_create"(fd))
					return 0;
			}

			int err = timerfd_settime(fd, 0, &its, null);

			if (catchError!"timer_settime"(err))
				return 0;
			epoll_event _event;

			EventType evtype;
			TimerHandler evh;
			evh.ctxt = ctxt;
			
			evtype = EventType.Timer;
			evh.fct = (AsyncTimer ctxt) {
				try {
					ctxt.handler();
				} catch (Exception e) {
					//setInternalError!"AsyncTimer handler"(Status.ERROR);
				}
			};
			
			EventObject eobj;
			eobj.timerHandler = evh;
			
			EventInfo* evinfo;
			
			if (!ctxt.evInfo) {
				try evinfo = FreeListObjectAlloc!EventInfo.alloc(fd, evtype, eobj, m_instanceId);
				catch (Exception e) {
					assert(false, "Failed to allocate resources: " ~ e.msg);
				}
				
				ctxt.evInfo = evinfo;
			}

			_event.events |= EPOLLIN | EPOLLET;
			_event.data.ptr = evinfo;
			if (ctxt.id > 0)
				err = epoll_ctl(m_epollfd, EPOLL_CTL_DEL, ctxt.id, null); 

			err = epoll_ctl(m_epollfd, EPOLL_CTL_ADD, fd, &_event); 

			if (catchError!"timer_epoll_add"(err))
				return 0;
			return fd;
		}
		else /* if KQUEUE */
		{
			// todo: EVFILT_TIMER

			import event.kqueue;
			fd_t fd = ctxt.id;

			if (ctxt.id == 0)
				fd = cast(fd_t) createIndex();
			EventType evtype;
			TimerHandler evh;
			evh.ctxt = ctxt;

			evtype = EventType.Timer;
			evh.fct = (AsyncTimer ctxt) {
				try {
					ctxt.handler();
				} catch (Exception e) {
					//setInternalError!"AsyncTimer handler"(Status.ERROR);
				}
			};
			
			EventObject eobj;
			eobj.timerHandler = evh;
			
			EventInfo* evinfo;

			if (!ctxt.evInfo) {
				try evinfo = FreeListObjectAlloc!EventInfo.alloc(fd, evtype, eobj, m_instanceId);
				catch (Exception e) {
					assert(false, "Failed to allocate resources: " ~ e.msg);
				}

				ctxt.evInfo = evinfo;
			}
			kevent_t _event;

			int msecs = cast(int) timeout.total!"msecs";

			// www.khmere.com/freebsd_book/html/ch06.html - EV_CLEAR set internally

			EV_SET(&_event, fd, EVFILT_TIMER, EV_ADD | EV_ENABLE, 0, msecs, cast(void*) evinfo);

			if (ctxt.oneShot)
				event.flags |= EV_ONESHOT;

			int err = kevent(m_kqueuefd, &_event, 1, null, 0, null);

			if (catchError!"kevent_timer_add"(err))
				return 0;

			return fd;

		}
	}

	bool kill(AsyncTCPConnection ctxt, bool forced = false)
	{
		m_status = StatusInfo.init;
		fd_t fd = ctxt.socket;
		scope(exit) {
			if (forced) {
				*ctxt.connected = false;
			}
			*ctxt.disconnecting = true;
		}
		if (*ctxt.connected)
			return closeSocket(fd, true, forced);
		else {
			return true;
		}
	}
	
	bool kill(AsyncTCPListener ctxt)
	{
		m_status = StatusInfo.init;
		nothrow void cleanup() {
			try FreeListObjectAlloc!EventInfo.free(ctxt.evInfo);
			catch { assert(false, "Failed to free resources"); }
		}

		scope(exit) {
			cleanup();
		}

		fd_t fd = ctxt.socket;

		return closeSocket(fd, false, true);
	}
	
	bool kill(AsyncNotifier ctxt)
	{
		static if (EPOLL)
		{
			import core.sys.posix.unistd : close;
			fd_t err = close(ctxt.id);

			if (catchError!"close(eventfd)"(err))
				return false;

			try FreeListObjectAlloc!EventInfo.free(ctxt.evInfo);
			catch (Exception e){ assert(false, "Error freeing resources"); }

			return true;
		}
		else /* if KQUEUE */
		{
			scope(exit) destroyIndex(ctxt);
			
			import event.kqueue;

			if (ctxt.id == fd_t.init)
				return false;

			kevent_t _event;
			EV_SET(&_event, ctxt.id, EVFILT_USER, EV_DELETE | EV_DISABLE, 0, 0, null);
			
			int err = kevent(m_kqueuefd, &_event, 1, null, 0, null);

			try FreeListObjectAlloc!EventInfo.free(ctxt.evInfo);
			catch (Exception e){ assert(false, "Error freeing resources"); }

			if (catchError!"kevent_del(notifier)"(err)) {
				return false;
			}
			return true;
		}

	}
	
	bool kill(shared AsyncSignal ctxt)
	{

		static if (EPOLL) {
			ctxt.evInfo = null;
		}
		else 
		{
			m_status = StatusInfo.init;
			destroyIndex(ctxt);
		}
		return true;
	}
		
	bool kill(AsyncTimer ctxt) {
		import core.sys.posix.time;
		m_status = StatusInfo.init;

		static if (EPOLL)
		{
			import core.sys.posix.unistd : close;
			fd_t err = close(ctxt.id);
			if (catchError!"timer_kill"(err))
				return false;

			if (ctxt.evInfo) {
				try FreeListObjectAlloc!EventInfo.free(ctxt.evInfo);
				catch (Exception e) { assert(false, "Failed to free resources: " ~ e.msg); }
			}
			
		}
		else /* if KQUEUE */
		{
			import event.kqueue;

			scope(exit) 
				destroyIndex(ctxt);

			if (ctxt.evInfo) {
				try FreeListObjectAlloc!EventInfo.free(ctxt.evInfo);
				catch (Exception e) { assert(false, "Failed to free resources: " ~ e.msg); }
			}
			kevent_t _event;
			EV_SET(&_event, ctxt.id, EVFILT_TIMER, EV_DELETE, 0, 0, null);
			int err = kevent(m_kqueuefd, &_event, 1, null, 0, null);
			if (catchError!"kevent_del(timer)"(err))
				return false;
		}
		return true;
	}

	bool kill(AsyncUDPSocket ctxt) {
		import core.sys.posix.unistd : close;


		m_status = StatusInfo.init;
		
		fd_t fd = ctxt.socket;
		fd_t err = close(fd);

		if (catchError!"udp close"(err)) 
			return false;

		static if (!EPOLL)
		{
			import event.kqueue;
			kevent_t[2] events;
			EV_SET(&(events[0]), ctxt.socket, EVFILT_READ, EV_DELETE, 0, 0, null);
			EV_SET(&(events[1]), ctxt.socket, EVFILT_WRITE, EV_DELETE, 0, 0, null);
			err = kevent(m_kqueuefd, &(events[0]), 2, null, 0, null);

			if (catchError!"event_del(udp)"(err)) 
				return false;
		}


		try FreeListObjectAlloc!EventInfo.free(ctxt.evInfo);
		catch (Exception e){
			assert(false, "Failed to free resources: " ~ e.msg);
		}

		return true;
	}


	bool setOption(T)(fd_t fd, TCPOption option, in T value) {
		m_status = StatusInfo.init;
		import std.traits : isIntegral;

		import core.sys.posix.sys.socket : socklen_t, setsockopt, SO_KEEPALIVE, SO_RCVBUF, SO_SNDBUF, SO_RCVTIMEO, SO_SNDTIMEO, SO_LINGER, SOL_SOCKET;
		import std.c.linux.socket : IPPROTO_TCP, TCP_NODELAY, TCP_QUICKACK, TCP_KEEPCNT, TCP_KEEPINTVL, TCP_KEEPIDLE, TCP_CONGESTION, TCP_CORK, TCP_DEFER_ACCEPT;
		int err;
		nothrow bool errorHandler() {
			if (catchError!"setOption:"(err)) {
				try m_status.text ~= option.to!string;
				catch (Exception e){ assert(false, "to!string conversion failure"); }
				return false;
			}

			return true;
		}
		final switch (option) {
			case TCPOption.NODELAY: // true/false
				static if (!is(T == bool))
					assert(false, "NODELAY value type must be bool, not " ~ T.stringof);
				else {
					int val = value?1:0;
					socklen_t len = val.sizeof;
					err = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &val, len);
					return errorHandler();
				}
			case TCPOption.QUICK_ACK:
				static if (!is(T == bool))
					assert(false, "QUICK_ACK value type must be bool, not " ~ T.stringof);
				else {
					static if (EPOLL) {
						int val = value?1:0;
						socklen_t len = val.sizeof;
						err = setsockopt(fd, IPPROTO_TCP, TCP_QUICKACK, &val, len);
						return errorHandler();
					}
					else /* not linux */ {
						return false;
					}
				}
			case TCPOption.KEEPALIVE_ENABLE: // true/false
				static if (!is(T == bool))
					assert(false, "KEEPALIVE_ENABLE value type must be bool, not " ~ T.stringof);
				else
				{
					int val = value?1:0;
					socklen_t len = val.sizeof;
					err = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &val, len);
					return errorHandler();
				}
			case TCPOption.KEEPALIVE_COUNT: // ##
				static if (!isIntegral!T)
					assert(false, "KEEPALIVE_COUNT value type must be integral, not " ~ T.stringof);
				else {
					int val = value.total!"msecs".to!uint;
					socklen_t len = val.sizeof;
					err = setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &val, len);
					return errorHandler();
				}
			case TCPOption.KEEPALIVE_INTERVAL: // wait ## seconds
				static if (!is(T == Duration))
					assert(false, "KEEPALIVE_INTERVAL value type must be Duration, not " ~ T.stringof);
				else {
					int val = value.total!"seconds".to!uint;
					socklen_t len = val.sizeof;
					err = setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &val, len);
					return errorHandler();
				}
			case TCPOption.KEEPALIVE_DEFER: // wait ## seconds until start
				static if (!is(T == Duration))
					assert(false, "KEEPALIVE_DEFER value type must be Duration, not " ~ T.stringof);
				else {
					int val = value.total!"seconds".to!uint;
					socklen_t len = val.sizeof;
					err = setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &val, len);
					return errorHandler();
				}
			case TCPOption.BUFFER_RECV: // bytes
				static if (!isIntegral!T)
					assert(false, "BUFFER_RECV value type must be integral, not " ~ T.stringof);
				else {
					int val = value.to!int;
					socklen_t len = val.sizeof;
					err = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &val, len);
					return errorHandler();
				}
			case TCPOption.BUFFER_SEND: // bytes
				static if (!isIntegral!T)
					assert(false, "BUFFER_SEND value type must be integral, not " ~ T.stringof);
				else {
					int val = value.to!int;
					socklen_t len = val.sizeof;
					err = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &val, len);
					return errorHandler();
				}
			case TCPOption.TIMEOUT_RECV:
				static if (!is(T == Duration))
					assert(false, "TIMEOUT_RECV value type must be Duration, not " ~ T.stringof);
				else {
					time_t secs = value.split!("seconds", "usecs")().seconds;
					suseconds_t us = value.split!("seconds", "usecs")().usecs.to!suseconds_t;
					timeval t = timeval(secs, us);
					socklen_t len = t.sizeof;
					err = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, len);
					return errorHandler();
				}
			case TCPOption.TIMEOUT_SEND:
				static if (!is(T == Duration))
					assert(false, "TIMEOUT_SEND value type must be Duration, not " ~ T.stringof);
				else {
					time_t secs = value.split!("seconds", "usecs")().seconds;
					suseconds_t us = value.split!("seconds", "usecs")().usecs.to!suseconds_t;
					timeval t = timeval(secs, us);
					socklen_t len = t.sizeof;
					err = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &t, len);
					return errorHandler();
				}
			case TCPOption.TIMEOUT_HALFOPEN:
				static if (!is(T == Duration))
					assert(false, "TIMEOUT_SEND value type must be Duration, not " ~ T.stringof);
				else {
					uint val = value.total!"msecs".to!uint;
					socklen_t len = val.sizeof;
					err = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &val, len);
					return errorHandler();
				}
			case TCPOption.LINGER: // bool onOff, int seconds
				static if (!is(T == Tuple!(bool, int)))
					assert(false, "LINGER value type must be Tuple!(bool, int), not " ~ T.stringof);
				else {
					linger l = linger(val[0]?1:0, val[1]);
					socklen_t llen = l.sizeof;
					err = setsockopt(fd, SOL_SOCKET, SO_LINGER, &l, llen);
					return errorHandler();
				}
			case TCPOption.CONGESTION:
				static if (!isIntegral!T)
					assert(false, "CONGESTION value type must be integral, not " ~ T.stringof);
				else {
					int val = value.to!int;
					len = int.sizeof;
					err = setsockopt(fd, IPPROTO_TCP, TCP_CONGESTION, &val, len);
					return errorHandler();
				}
			case TCPOption.CORK:
				static if (!isIntegral!T)
					assert(false, "CORK value type must be int, not " ~ T.stringof);
				else {
					static if (EPOLL) {
						int val = value.to!int;
						socklen_t len = val.sizeof;
						err = setsockopt(fd, IPPROTO_TCP, TCP_CORK, &val, len);
						return errorHandler();
					}
					else /* if KQUEUE */ {
						int val = value.to!int;
						socklen_t len = val.sizeof;
						err = setsockopt(fd, IPPROTO_TCP, TCP_NOPUSH, &val, len);
						return errorHandler();

					}
				}
			case TCPOption.DEFER_ACCEPT: // seconds
				static if (!isIntegral!T)
					assert(false, "DEFER_ACCEPT value type must be integral, not " ~ T.stringof);
				else {
					static if (EPOLL) {
						int val = value.to!int;
						socklen_t len = val.sizeof;
						err = setsockopt(fd, IPPROTO_TCP, TCP_DEFER_ACCEPT, &val, len);
						return errorHandler();
					}
					else /* if KQUEUE */ {
						// todo: Emulate DEFER_ACCEPT with ACCEPT_FILTER(9)
						/*int val = value.to!int;
						socklen_t len = val.sizeof;
						err = setsockopt(fd, SOL_SOCKET, SO_ACCEPTFILTER, &val, len);
						return errorHandler();
						*/
					}
				}
		}

	}

	uint recv(in fd_t fd, ref ubyte[] data)
	{
		m_status = StatusInfo.init;
		import core.sys.posix.sys.socket : recv;
		int ret = cast(int) recv(fd, cast(void*) data.ptr, data.length, cast(int)0);
		
		static if (LOG) log(".recv " ~ ret.to!string ~ " bytes of " ~ data.length.to!string ~ " @ " ~ fd.to!string);
		if (catchError!".recv"(ret)){ // ret == SOCKET_ERROR == -1 ?
			if (m_error == EWOULDBLOCK)
				m_status.code = Status.ASYNC;

			return 0; // TODO: handle some errors more specifically
		}

		m_status.code = Status.OK;
		
		return cast(uint) ret < 0 ? 0 : ret;
	}
	
	uint send(in fd_t fd, in ubyte[] data)
	{
		m_status = StatusInfo.init;
		import core.sys.posix.sys.socket : send;
		int ret = cast(int) send(fd, cast(const(void)*) data.ptr, data.length, cast(int)0);

		if (catchError!"send"(ret)) { // ret == -1
			if (m_error == EWOULDBLOCK) {
				m_status.code = Status.ASYNC;
				return 0;
			}
		}
		m_status.code = Status.OK;
		return cast(uint) ret < 0 ? 0 : ret;
	}

	uint recvFrom(in fd_t fd, ref ubyte[] data, ref NetworkAddress addr)
	{
		import core.sys.posix.sys.socket;

		m_status = StatusInfo.init;

		socklen_t addrLen;
		addr.family = AF_INET;
		long ret = recvfrom(fd, cast(void*) data.ptr, data.length, 0, addr.sockAddr, &addrLen);
		
		if (addrLen > addr.sockAddrLen) {
			addr.family = AF_INET6;
		}
		
		try log("RECVFROM " ~ ret.to!string ~ "B"); catch {}
		if (catchError!".recvfrom"(ret)) { // ret == -1
			if (m_error == EWOULDBLOCK)
				m_status.code = Status.ASYNC;
			return 0;
		}

		m_status.code = Status.OK;
		
		return cast(uint) ret;
	}
	
	uint sendTo(in fd_t fd, in ubyte[] data, in NetworkAddress addr)
	{
		import core.sys.posix.sys.socket;

		m_status = StatusInfo.init;

		try log("SENDTO " ~ data.length.to!string ~ "B");
		catch{}
		long ret = sendto(fd, cast(void*) data.ptr, data.length, 0, addr.sockAddr, addr.sockAddrLen);
		
		if (catchError!".sendto"(ret)) { // ret == -1
			if (m_error == EWOULDBLOCK)
				m_status.code = Status.ASYNC;
			return 0;
		}

		m_status.code = Status.OK;
		return cast(uint) ret;
	}

	bool notify(in fd_t fd, AsyncNotifier ctxt)
	{
		static if (EPOLL)
		{
			import core.sys.posix.unistd : write;

			long val = 1;
			fd_t err = cast(fd_t) write(fd, &val, long.sizeof);
			
			if (catchError!"write(notify)"(err)) {
				return false;
			}
			return true;
		}
		else /* if KQUEUE */
		{
			import event.kqueue;
			
			kevent_t event;
			EV_SET(&event, fd, EVFILT_USER, EV_ENABLE | EV_CLEAR, NOTE_TRIGGER | 0x1, 0, ctxt.evInfo);
			int err = kevent(m_kqueuefd, &event, 1, null, 0, null);
			
			if (catchError!"kevent_notify"(err)) {
				return false;
			}
			return true;
		}
	}

	bool notify(in fd_t fd, shared AsyncSignal ctxt)
	{
		static if (EPOLL) 
		{
			import core.sys.posix.signal;

			sigval sigvl;
			fd_t err;
			sigvl.sival_ptr = cast(void*) ctxt;
			import core.thread : getpid;
			try err = sigqueue(getpid(), fd, sigvl); catch {}
			if (catchError!"sigqueue"(err)) {
				return false;
			}
		}
		else /* if KQUEUE */ 
		{

			import core.thread : getpid;
			import core.sys.posix.signal : kill;

			addSignal(ctxt);

			try {
				log("Notified fd: " ~ fd.to!string ~ " of PID " ~ getpid().to!string); 
				import core.sys.posix.signal : SIGUSR1;
				int err = kill(getpid(), SIGUSR1);
				if (catchError!"notify(signal)"(err))
					assert(false, "Signal could not be raised");
			} catch {}
		}

		return true;
	}

	uint read(in fd_t fd, ref ubyte[] data)
	{
		m_status = StatusInfo.init;
		return 0;
	}
	
	uint write(in fd_t fd, in ubyte[] data)
	{
		m_status = StatusInfo.init;
		return 0;
	}

	private bool closeRemoteSocket(fd_t fd, bool forced) {
		
		int err;
		log("shutdown");
		import core.sys.posix.sys.socket : shutdown, SHUT_WR, SHUT_RDWR;
		if (forced) 
			err = shutdown(fd, SHUT_RDWR);
		else
			err = shutdown(fd, SHUT_WR);

		static if (!EPOLL) {
			import event.kqueue;
			kevent_t[2] events;
			try log("!!DISC delete events"); catch {}
			EV_SET(&(events[0]), fd, EVFILT_READ, EV_DELETE | EV_DISABLE, 0, 0, null);
			EV_SET(&(events[1]), fd, EVFILT_WRITE, EV_DELETE | EV_DISABLE, 0, 0, null);
			kevent(m_kqueuefd, &(events[0]), 2, null, 0, null);

		}

		if (catchError!"shutdown"(err))
			return false;

		return true;
	}

	// for connected sockets
	bool closeSocket(fd_t fd, bool connected, bool forced = false)
	{

		if (connected && !closeRemoteSocket(fd, forced) && !forced)
			return false;
		
		if (!connected || forced) {
			// todo: flush the socket here?

			import core.sys.posix.unistd : close;
			log("close");
			int err = close(fd);

			if (catchError!"closesocket"(err)) 
				return false;
		}
		return true;
	}

	
	NetworkAddress getAddressFromIP(in string ipAddr, in ushort port = 0, in bool ipv6 = false, in bool tcp = true) 
	in {
		import event.validator;
		debug assert(validateIPv4(ipAddr) || validateIPv6(ipAddr), "Trying to connect to an invalid IP address");
	}
	body {
		import std.c.linux.socket : addrinfo, AI_NUMERICHOST, AI_NUMERICSERV;
		addrinfo hints;
		hints.ai_flags |= AI_NUMERICHOST | AI_NUMERICSERV; // Specific to an IP resolver!

		return getAddressInfo(ipAddr, port, ipv6, tcp, hints);
	}


	NetworkAddress getAddressFromDNS(in string host, in ushort port = 0, in bool ipv6 = true, in bool tcp = true)
	in { 
		import event.validator;	
		debug assert(validateHost(host), "Trying to connect to an invalid domain"); 
	}
	body {
		import std.c.linux.socket : addrinfo;
		addrinfo hints;
		return getAddressInfo(host, port, ipv6, tcp, hints);
	}
	
	void setInternalError(string TRACE)(in Status s, in string details = "", in error_t error = EPosix.EACCES)
	{
		if (details.length > 0)
			m_status.text = TRACE ~ ": " ~ details;
		else m_status.text = TRACE;
		m_error = error;
		m_status.code = s;
		static if(LOG) log(m_status);
	}
private:	

	// socket must not be connected
	bool setNonBlock(fd_t fd) {
		import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;
		int flags = fcntl(fd, F_GETFL);
		flags |= O_NONBLOCK;
		int err = fcntl(fd, F_SETFL, flags);
		if (catchError!"F_SETFL O_NONBLOCK"(err)) {
			closeSocket(fd, false);
			return false;
		}
		return true;
	}
	
	bool onTCPAccept(fd_t fd, TCPAcceptHandler del, int events)
	{
		import core.sys.posix.sys.socket : AF_INET, AF_INET6, socklen_t, accept;

		static if (EPOLL) 
		{
			const uint epoll_events = cast(uint) events;
			const bool incoming = cast(bool) (epoll_events & EPOLLIN);
			const bool error = cast(bool) (epoll_events & EPOLLERR);
		}
		else 
		{
			import event.kqueue;
			const short kqueue_events = cast(short) (events >> 16);
			const ushort kqueue_flags = cast(ushort) (events & 0xffff);
			const bool incoming = cast(bool)(kqueue_events & EVFILT_READ);
			const bool error = cast(bool)(kqueue_flags & EV_ERROR);
		}
		
		if (incoming) { // accept incoming connection
			NetworkAddress addr;
			addr.family = AF_INET;
			socklen_t addrlen = addr.sockAddrLen;

			bool ret;

			/// Accept the connection and create a client socket
			fd_t csock = accept(fd, addr.sockAddr, &addrlen); // todo: use accept4 to set SOCK_NONBLOCK


			if (catchError!".accept"(csock)) {
				ret = false;
				return ret;
			}

			// Make non-blocking so subsequent calls to recv/send return immediately
			if (!setNonBlock(csock)) {
				ret = false;
				return ret;
			}

			// Set client address family based on address length
			if (addrlen > addr.sockAddrLen)
				addr.family = AF_INET6;
			if (addrlen == socklen_t.init) {
				setInternalError!"addrlen"(Status.ABORT);
				import core.sys.posix.unistd : close;
				close(csock);
				{
					ret = false;
					return ret;
				}
			}

			// Allocate a new connection handler object
			AsyncTCPConnection conn;
			try conn = FreeListObjectAlloc!AsyncTCPConnection.alloc(m_evLoop);
			catch (Exception e){ assert(false, "Allocation failure"); }
			conn.peer = addr;
			conn.socket = csock;
			conn.inbound = true;

			nothrow bool closeClient() {
				try FreeListObjectAlloc!AsyncTCPConnection.free(conn);
				catch (Exception e){ assert(false, "Free failure"); }
				closeSocket(csock, true, true);
				{
					ret = false;
					return ret;
				}
			}

			// Get the connection handler from the callback
			TCPEventHandler evh;
			try {
				evh = del(conn);
				if (evh == TCPEventHandler.init || !initTCPConnection(csock, conn, evh, true)) {
					return closeClient();
				}
				log("Connection Started");
			}
			catch (Exception e) {
				return closeClient();
			}

			// Announce connection state to the connection handler
			try {
				log("Connected to: " ~ addr.toString());
				*evh.conn.connected = true;
				evh(TCPEvent.CONNECT);
			}
			catch (Exception e) {
				setInternalError!"del@TCPEvent.CONNECT"(Status.ABORT);
				{
					ret = false;
					return ret;
				}
			}


		}
		
		if (error) { // socket failure
			m_status.text = "listen socket error";
			int err;
			import core.sys.posix.sys.socket : getsockopt, socklen_t, SOL_SOCKET, SO_ERROR;
			socklen_t len = int.sizeof;
			getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
			m_error = cast(error_t) err;
			m_status.code = Status.ABORT;
			static if(LOG) log(m_status);

			// call with null to announce a failure
			try del(null);
			catch(Exception e){ assert(false, "Failure calling TCPAcceptHandler(null)"); }

			/// close the listener?
			// closeSocket(fd, false);
		}
		return true;
	}

	bool onUDPTraffic(fd_t fd, UDPHandler del, int events) 
	{
		static if (EPOLL) 
		{
			const uint epoll_events = cast(uint) events;
			const bool read = cast(bool) (epoll_events & EPOLLIN);
			const bool write = cast(bool) (epoll_events & EPOLLOUT);
			const bool error = cast(bool) (epoll_events & EPOLLERR);
		}
		else 
		{
			import event.kqueue;
			const short kqueue_events = cast(short) (events >> 16);
			const ushort kqueue_flags = cast(ushort) (events & 0xffff);
			const bool read = cast(bool) (kqueue_events & EVFILT_READ);
			const bool write = cast(bool) (kqueue_events & EVFILT_WRITE);
			const bool error = cast(bool) (kqueue_flags & EV_ERROR);
		}

		if (read) {
			try {
				del(UDPEvent.READ);
			}
			catch (Exception e) {
				setInternalError!"del@UDPEvent.READ"(Status.ABORT);
				return false;
			}
		}

		if (write) { 

			try {
				del(UDPEvent.WRITE);
			}
			catch (Exception e) {
				setInternalError!"del@UDPEvent.WRITE"(Status.ABORT);
				return false;
			}
		}

		if (error) // socket failure
		{ 

			import core.sys.posix.sys.socket : socklen_t, getsockopt, SOL_SOCKET, SO_ERROR;
			import core.sys.posix.unistd : close;
			int err;
			socklen_t errlen = err.sizeof;
			getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errlen);
			setInternalError!"EPOLLERR"(Status.ABORT, null, cast(error_t)err);
			close(fd);
		}
		
		return true;
	}

	bool onTCPTraffic(fd_t fd, TCPEventHandler del, int events, bool* connected, bool* disconnecting) 
	{
		log("TCP Traffic at FD#" ~ fd.to!string);

		static if (EPOLL) 
		{
			const uint epoll_events = cast(uint) events;
			const bool connect = ((cast(bool) (epoll_events & EPOLLIN)) || (cast(bool) (epoll_events & EPOLLOUT))) && !(*disconnecting) && !(*connected);
			const bool read = cast(bool) (epoll_events & EPOLLIN);
			const bool write = cast(bool) (epoll_events & EPOLLOUT);
			const bool error = cast(bool) (epoll_events & EPOLLERR);
			const bool close = (cast(bool) (epoll_events & EPOLLRDHUP)) || (cast(bool) (events & EPOLLHUP));
		}
		else /* if KQUEUE */
		{
			import event.kqueue;
			const short kqueue_events = cast(short) (events >> 16);
			const ushort kqueue_flags = cast(ushort) (events & 0xffff);
			const bool connect = cast(bool) ((kqueue_events & EVFILT_READ || kqueue_events & EVFILT_WRITE) && !(*disconnecting) && !(*connected));
			const bool read = cast(bool) (kqueue_events & EVFILT_READ);
			const bool write = cast(bool) (kqueue_events & EVFILT_WRITE);
			const bool error = cast(bool) (kqueue_flags & EV_ERROR);
			const bool close = cast(bool) (kqueue_flags & EV_EOF);
		}

		if (connect) 
		{
			try log("!connect"); catch {}
			*connected = true;
			try del(TCPEvent.CONNECT);
			catch (Exception e) {
				setInternalError!"del@TCPEvent.CONNECT"(Status.ABORT);
				return false;
			}
			return true;
		}

		if (read && *connected && !*disconnecting)
		{
			try log("!read"); catch {}
			try del(TCPEvent.READ);
			catch (Exception e) {
				setInternalError!"del@TCPEvent.READ"(Status.ABORT);
				return false;
			}
		}

		if (write && *connected && !*disconnecting) 
		{
			try log("!write"); catch {}
			try del(TCPEvent.WRITE);
			catch (Exception e) {
				setInternalError!"del@TCPEvent.WRITE"(Status.ABORT);
				return false;
			}
		}
		
		if (close && *connected && !*disconnecting) 
		{
			try log("!close"); catch {}
			// todo: See if this hack is still necessary
			if (!*connected && *disconnecting)
				return true;

			try del(TCPEvent.CLOSE);
			catch (Exception e) {
				setInternalError!"del@TCPEvent.CLOSE"(Status.ABORT);
				return false;
			}
			closeSocket(fd, !*disconnecting, *connected);

			m_status.code = Status.ABORT;
			*disconnecting = true;
			*connected = false;
			del.conn.socket = 0;

			try FreeListObjectAlloc!EventInfo.free(del.conn.evInfo);
			catch (Exception e){ assert(false, "Error freeing resources"); }

			if (del.conn.inbound) {
				log("Freeing inbound connection");
				try FreeListObjectAlloc!AsyncTCPConnection.free(del.conn);
				catch (Exception e){ assert(false, "Error freeing resources"); }
			}

			return true;
		}
		
		if (error) 
		{
			import core.sys.posix.sys.socket : socklen_t, getsockopt, SOL_SOCKET, SO_ERROR;
			int err;
			socklen_t errlen = err.sizeof;
			getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errlen);
			try log("ERROR was found! : "~ err.to!string); catch (Exception e){ assert(false, e.msg); }
			setInternalError!"EPOLLERR"(Status.ABORT, null, cast(error_t)err);
			
			m_status.code = Status.ABORT;
			closeSocket(fd, true, true);
		}

		return true;
	}
	
	bool initUDPSocket(fd_t fd, AsyncUDPSocket ctxt, UDPHandler del)
	{
		import core.sys.posix.sys.socket;
		import core.sys.posix.unistd;

		fd_t err;

		EventObject eo;
		eo.udpHandler = del;
		EventInfo* ev;
		try ev = FreeListObjectAlloc!EventInfo.alloc(fd, EventType.UDPSocket, eo, m_instanceId);
		catch (Exception e){ assert(false, "Allocation error"); }
		ctxt.evInfo = ev;
		nothrow bool closeAll() {
			try FreeListObjectAlloc!EventInfo.free(ev);
			catch(Exception e){ assert(false, "Failed to free resources"); }
			ctxt.evInfo = null;
			// socket will be closed by caller if return false
			return false;
		}

		static if (EPOLL)
		{
			epoll_event _event;
			_event.data.ptr = ev;
			_event.events = EPOLLIN | EPOLLOUT | EPOLLET;
			err = epoll_ctl(m_epollfd, EPOLL_CTL_ADD, fd, &_event);
			if (catchError!"epoll_ctl"(err)) {
				return closeAll();
			}
			nothrow void deregisterEvent() {}
		}
		else /* if KQUEUE */
		{
			import event.kqueue;
			kevent_t[2] _event;
			EV_SET(&(_event[0]), fd, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, ev);
			EV_SET(&(_event[1]), fd, EVFILT_WRITE, EV_ADD | EV_ENABLE, 0, 0, ev);
			err = kevent(m_kqueuefd, &(_event[0]), 2, null, 0, null);
			if (catchError!"kevent_add_udp"(err))
				return closeAll();
			
			nothrow void deregisterEvent() {
				EV_SET(&(_event[0]), fd, EVFILT_READ, EV_DELETE | EV_DISABLE, 0, 0, null);
				EV_SET(&(_event[1]), fd, EVFILT_WRITE, EV_DELETE | EV_DISABLE, 0, 0, null);
				kevent(m_kqueuefd, &(_event[0]), 2, null, 0, cast(timespec*) null);
			}

		}

		/// Start accepting packets
		err = bind(fd, ctxt.local.sockAddr, ctxt.local.sockAddrLen);
		if (catchError!"bind"(err)) {
			deregisterEvent();
			return closeAll();
		}

		return true;
	}


	bool initTCPListener(fd_t fd, AsyncTCPListener ctxt, TCPAcceptHandler del)
	in {
		assert(ctxt.local !is NetworkAddress.init);
	}
	body {
		import core.sys.posix.sys.socket : bind, listen, SOMAXCONN;
		fd_t err;

		/// Create callback object
		EventObject eo;
		eo.tcpAcceptHandler = del;
		EventInfo* ev;

		try ev = FreeListObjectAlloc!EventInfo.alloc(fd, EventType.TCPAccept, eo, m_instanceId);
		catch (Exception e){ assert(false, "Allocation error"); }
		ctxt.evInfo = ev;
		nothrow bool closeAll() {
			try FreeListObjectAlloc!EventInfo.free(ev);
			catch(Exception e){ assert(false, "Failed free"); }
			ctxt.evInfo = null;
			// Socket is closed by run()
			//closeSocket(fd, false);
			return false;
		}

		/// Add socket to event loop
		static if (EPOLL)
		{
			epoll_event _event;
			_event.data.ptr = ev;
			_event.events = EPOLLIN | EPOLLET;
			err = epoll_ctl(m_epollfd, EPOLL_CTL_ADD, fd, &_event);
			if (catchError!"epoll_ctl_add"(err))
				return closeAll();

			nothrow void deregisterEvent() {
				// epoll cleans itself when closing the socket
			}
		}
		else /* if KQUEUE */
		{
			kevent_t _event;
			EV_SET(&_event, fd, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, ev);
			err = kevent(m_kqueuefd, &_event, 1, null, 0, null);
			if (catchError!"kevent_add_listener"(err))
				return closeAll();

			nothrow void deregisterEvent() {
				EV_SET(&_event, fd, EVFILT_READ, EV_CLEAR | EV_DISABLE, 0, 0, null);
				kevent(m_kqueuefd, &_event, 1, null, 0, null);
				// wouldn't know how to deal with errors here...
			}
		}

		/// Bind and listen to socket

		err = bind(fd, ctxt.local.sockAddr, ctxt.local.sockAddrLen);
		if (catchError!"bind"(err)) {
			deregisterEvent();
			return closeAll();
		}

		err = listen(fd, SOMAXCONN);
		if (catchError!"listen"(err)) {
			deregisterEvent();
			return closeAll();
		}

		return true;
	}

	bool initTCPConnection(fd_t fd, AsyncTCPConnection ctxt, TCPEventHandler del, bool inbound = false)
	in { 
		assert(ctxt.peer.port != 0, "Connecting to an invalid port");
	}
	body {

		fd_t err;

		/// Create callback object
		import core.sys.posix.sys.socket : connect;
		EventObject eo;
		eo.tcpEvHandler = del;
		EventInfo* ev;

		try ev = FreeListObjectAlloc!EventInfo.alloc(fd, EventType.TCPTraffic, eo, m_instanceId);
		catch (Exception e){ assert(false, "Allocation error"); }
		assert(ev !is null);
		ctxt.evInfo = ev;
		nothrow bool destroyEvInfo() {
			try FreeListObjectAlloc!EventInfo.free(ev);
			catch(Exception e){ assert(false, "Failed to free resources"); }
			ctxt.evInfo = null;

			// Socket will be closed by run()
			// closeSocket(fd, false);
			return false;
		}

		/// Add socket and callback object to event loop
		static if (EPOLL)
		{
			epoll_event _event = void;
			_event.data.ptr = ev;
			_event.events = 0 | EPOLLIN | EPOLLOUT | EPOLLERR | EPOLLHUP | EPOLLRDHUP | EPOLLET;
			err = epoll_ctl(m_epollfd, EPOLL_CTL_ADD, fd, &_event);
			log("Connection FD#" ~ fd.to!string ~ " added to " ~ m_epollfd.to!string);
			if (catchError!"epoll_ctl_add"(err))
				return destroyEvInfo();

			nothrow void deregisterEvent() {
				// will be handled automatically when socket is closed
			}
		}
		else /* if KQUEUE */
		{
			import event.kqueue;
			kevent_t[2] events = void;
			try log("Register event ptr " ~ ev.to!string); catch {}
			assert(ev.evType == EventType.TCPTraffic, "Bad event type for TCP Connection");
			EV_SET(&(events[0]), fd, EVFILT_READ, EV_ADD | EV_ENABLE | EV_CLEAR, 0, 0, cast(void*) ev);
			EV_SET(&(events[1]), fd, EVFILT_WRITE, EV_ADD | EV_ENABLE | EV_CLEAR, 0, 0, cast(void*) ev);
			assert((cast(EventInfo*)events[0].udata) == ev && (cast(EventInfo*)events[1].udata) == ev);
			assert((cast(EventInfo*)events[0].udata).owner == m_instanceId && (cast(EventInfo*)events[1].udata).owner == m_instanceId);
			err = kevent(m_kqueuefd, &(events[0]), 2, null, 0, null);
			if (catchError!"kevent_add_tcp"(err))
				return destroyEvInfo();

			// todo: verify if this allocates on the GC?
			nothrow void deregisterEvent() {
				EV_SET(&(events[0]), fd, EVFILT_READ, EV_DELETE | EV_DISABLE, 0, 0, null);
				EV_SET(&(events[1]), fd, EVFILT_WRITE, EV_DELETE | EV_DISABLE, 0, 0, null);
				kevent(m_kqueuefd, &(events[0]), 2, null, 0, null);
				// wouldn't know how to deal with errors here...
			}
		}

		// Inbound objects are already connected
		if (inbound) return true;

		// Connect is blocking, but this makes the socket non-blocking for send/recv
		if (!setNonBlock(fd)) {
			deregisterEvent();
			return destroyEvInfo();
		}

		/// Start the connection
		err = connect(fd, ctxt.peer.sockAddr, ctxt.peer.sockAddrLen);
		if (catchErrorsEq!"connect"(err, [ tuple(cast(fd_t)SOCKET_ERROR, EPosix.EINPROGRESS, Status.ASYNC) ]))
			return true;
		if (catchError!"connect"(err)) {
			deregisterEvent();
			return destroyEvInfo();
		}

		return true;
	}

	bool catchError(string TRACE, T)(T val, T cmp = SOCKET_ERROR)
		if (isIntegral!T)
	{
		if (val == cmp) {
			m_status.text = TRACE;
			m_error = lastError();
			m_status.code = Status.ABORT;
			static if(LOG) log(m_status);
			return true;
		}
		return false;
	}

	bool catchSocketError(string TRACE)(fd_t fd)
	{
		m_status.text = TRACE;
		int err;
		import core.sys.posix.sys.socket : getsockopt, socklen_t, SOL_SOCKET, SO_ERROR;
		socklen_t len = int.sizeof;
		getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
		m_error = cast(error_t) err;
		if (m_error != EPosix.EOK) {
			m_status.code = Status.ABORT;
			static if(LOG) log(m_status);
			return true;
		}

		return false;
	}

	bool catchEvLoopErrors(string TRACE, T)(T val, Tuple!(T, Status)[] cmp ...)
		if (isIntegral!T)
	{
		if (val == SOCKET_ERROR) {
			int err = errno;
			foreach (validator ; cmp) {
				if (errno == validator[0]) {
					m_status.text = TRACE;
					m_error = lastError();
					m_status.code = validator[1];
					static if(LOG) log(m_status);
					return true;
				}
			}

			m_status.text = TRACE;
			m_status.code = Status.EVLOOP_FAILURE;
			m_error = lastError();
			log(m_status);
			return true;
		}
		return false;
	}

	/**
	 * If the value at val matches the tuple first argument T, get the last error,
	 * and if the last error matches tuple second argument error_t, set the Status as
	 * tuple third argument Status.
	 * 
	 * Repeats for each comparison tuple until a match in which case returns true.
	*/
	bool catchErrorsEq(string TRACE, T)(T val, Tuple!(T, error_t, Status)[] cmp ...)
		if (isIntegral!T)
	{
		error_t err;
		foreach (validator ; cmp) {
			if (val == validator[0]) {
				if (err is EPosix.init) err = lastError();
				if (err == validator[1]) {
					m_status.text = TRACE;
					m_status.code = validator[2];
					if (m_status.code == Status.EVLOOP_TIMEOUT) {
						log(m_status);
						break;
					}
					m_error = lastError();
					static if(LOG) log(m_status);
					return true;
				}
			}
		}
		return false;
	}


	error_t lastError() {
		try {
			return cast(error_t) errno;
		} catch(Exception e) {
			return EPosix.EACCES;
		}

	}
	
	void log(StatusInfo val)
	{
		version(none) {
			import std.stdio;
			try {
				writeln("Backtrace: ", m_status.text);
				writeln(" | Status:  ", m_status.code);
				writeln(" | Error: " , m_error);
				if ((m_error in EPosixMessages) !is null)
					writeln(" | Message: ", EPosixMessages[m_error]);
			} catch(Exception e) {
				return;
			}
		}
	}

	void log(T)(T val)
	{
		version(none) {
			import std.stdio;
			try {
				writeln(val);
			} catch(Exception e) {
				return;
			}
		}
	}

	NetworkAddress getAddressInfo(addrinfo)(in string host, ushort port, bool ipv6, bool tcp, ref addrinfo hints) 
	{
		m_status = StatusInfo.init;
		import core.sys.posix.sys.socket : AF_INET, AF_INET6, SOCK_DGRAM, SOCK_STREAM;
		import std.c.linux.socket : IPPROTO_TCP, IPPROTO_UDP, freeaddrinfo, getaddrinfo;

		NetworkAddress addr;
		addrinfo* infos;
		error_t err;
		if (ipv6) {
			addr.family = AF_INET6;
			hints.ai_family = AF_INET6;
		}
		else {
			addr.family = AF_INET;
			hints.ai_family = AF_INET;
		}
		if (tcp) {
			hints.ai_socktype = SOCK_STREAM;
			hints.ai_protocol = IPPROTO_TCP;
		}
		else {
			hints.ai_socktype = SOCK_DGRAM;
			hints.ai_protocol = IPPROTO_UDP;
		}

		static if (LOG) {
			log("Resolving " ~ host ~ ":" ~ port.to!string);
		}

		auto chost = host.toStringz();

		if (port != 0) {
			addr.port = port;
			const(char)* cPort = cast(const(char)*) port.to!string.toStringz;
			err = cast(error_t) getaddrinfo(chost, cPort, &hints, &infos);
		}
		else {
			err = cast(error_t) getaddrinfo(chost, null, &hints, &infos);
		}

		if (err != EPosix.EOK) {
			setInternalError!"getAddressInfo"(Status.ERROR, string.init, err);
			return NetworkAddress.init;
		}
		ubyte* pAddr = cast(ubyte*) infos.ai_addr;
		ubyte* data = cast(ubyte*) addr.sockAddr;
		data[0 .. infos.ai_addrlen] = pAddr[0 .. infos.ai_addrlen]; // perform bit copy
		freeaddrinfo(infos);
		return addr;
	}


	
}


static if (!EPOLL)
{
nothrow:
	import std.container : Array;
	import core.sync.mutex : Mutex;
	import core.sync.rwmutex : ReadWriteMutex;
	size_t g_evIdxCapacity;
	Array!size_t g_evIdxAvailable;

	// called on run
	size_t createIndex() {
		size_t idx;
		import std.algorithm : min;
		try {
			
			size_t getIdx() {
				
				if (!g_evIdxAvailable.empty) {
					immutable size_t ret = g_evIdxAvailable.back;
					g_evIdxAvailable.removeBack();
					return ret;
				}
				return 0;
			}
			
			idx = getIdx();
			if (idx == 0) {
				import std.range : iota;
				g_evIdxAvailable.insert( iota(g_evIdxCapacity, min(32, g_evIdxCapacity * 2), 1) );
				g_evIdxCapacity = min(32, g_evIdxCapacity * 2);
				idx = getIdx();
			}
			
		} catch {}
		
		return idx;
	}

	void destroyIndex(AsyncNotifier ctxt) {
		try {
			g_evIdxAvailable.insert(ctxt.id);		
		}
		catch (Exception e) {
			assert(false, "Error destroying index: " ~ e.msg);
		}
	}

	void destroyIndex(AsyncTimer ctxt) {
		try {
			g_evIdxAvailable.insert(ctxt.id);		
		}
		catch (Exception e) {
			assert(false, "Error destroying index: " ~ e.msg);
		}
	}

	static this() {
		try {
			g_evIdxAvailable.reserve(32);

			foreach (i; g_evIdxAvailable.length .. g_evIdxAvailable.capacity) {
				g_evIdxAvailable.insertBack(size_t.init);
			}
			g_evIdxCapacity = 32;
			g_idxCapacity = 32;
		}
		catch {}
	}


	size_t* g_threadId;
	size_t g_idxCapacity;
	Array!size_t g_idxAvailable;

	__gshared ReadWriteMutex gs_queueMutex;
	__gshared Array!(Array!AsyncSignal) gs_signalQueue;
	__gshared Array!(Array!size_t) gs_idxQueue; // signals notified

	shared static this() {
		try {
			gs_queueMutex = FreeListObjectAlloc!ReadWriteMutex.alloc();
			gs_signalQueue = Array!(Array!AsyncSignal)();
			gs_idxQueue = Array!(Array!size_t)();
		}
		catch (Exception e) {
			assert(false, "failed to allocate queue Mutex");
		}


	}

	// loop
	bool popSignals(ref AsyncSignal[] sigarr) {
		bool more;
		try {
			foreach (ref AsyncSignal sig; sigarr) {
				if (!sig)
					break;
				sig = null;
			}
			size_t len;
			synchronized(gs_queueMutex.reader) {

				if (gs_idxQueue.length <= *g_threadId || gs_idxQueue[*g_threadId].empty)
					return false;

				len = gs_idxQueue[*g_threadId].length;
				import std.stdio;
				if (sigarr.length < len) {
					more = true;
					len = sigarr.length;
				}

				size_t i;
				foreach (size_t idx; gs_idxQueue[*g_threadId][0 .. len]){
					sigarr[i] = gs_signalQueue[*g_threadId][idx];
					i++;
				}
			}

			synchronized (gs_queueMutex.writer) {
				gs_idxQueue[*g_threadId].linearRemove(gs_idxQueue[*g_threadId][0 .. len]);
			}
		}
		catch (Exception e) {
			assert(false, "Could not get pending signals: " ~ e.msg);
		}
		return more;
	}

	// notify
	void addSignal(shared AsyncSignal ctxt) {
		try {
			size_t thread_id = ctxt.threadId;
			bool must_resize;
			import std.stdio;
			synchronized (gs_queueMutex.writer) {
				if (gs_idxQueue.empty || gs_idxQueue.length < thread_id + 1) {
					gs_idxQueue.reserve(thread_id + 1);
					foreach (i; gs_idxQueue.length .. gs_idxQueue.capacity) {
						gs_idxQueue.insertBack(Array!size_t.init);
					}
				}
				if (gs_idxQueue[thread_id].empty)
				{
					gs_idxQueue[thread_id].reserve(32);
				}

				gs_idxQueue[thread_id].insertBack(ctxt.id);

			}

		}
		catch (Exception e) {
			assert(false, "Array error: " ~ e.msg);
		}
	}

	// called on run
	size_t createIndex(shared AsyncSignal ctxt) {
		size_t idx;
		import std.algorithm : max;
		try {
			bool must_resize;

			synchronized (gs_queueMutex.reader) {
				if (gs_signalQueue.length < *g_threadId)
					must_resize = true;
			}

			/// make sure the signal queue is big enough for this thread ID
			if (must_resize) {
				synchronized (gs_queueMutex.writer) {
					while (gs_signalQueue.length <= *g_threadId) 
						gs_signalQueue.insertBack(Array!AsyncSignal.init);
				}
			}

			size_t getIdx() {

				if (!g_idxAvailable.empty) {
					immutable size_t ret = g_idxAvailable.back;
					g_idxAvailable.removeBack();
					return ret;
				}
				return 0;
			}

			idx = getIdx();
			if (idx == 0) {
				import std.range : iota;
				g_idxAvailable.insert( iota(g_idxCapacity,  max(32, g_idxCapacity * 2), 1) );
				g_idxCapacity = max(32, g_idxCapacity * 2);
				idx = getIdx();
			}

			synchronized (gs_queueMutex.writer) {
				if (gs_signalQueue.empty || gs_signalQueue.length < *g_threadId + 1) {
					
					gs_signalQueue.reserve(*g_threadId + 1);
					foreach (i; gs_signalQueue.length .. gs_signalQueue.capacity) {
						gs_signalQueue.insertBack(Array!AsyncSignal.init);
					}
					
				}

				if (gs_signalQueue[*g_threadId].empty || gs_signalQueue[*g_threadId].length < idx + 1) {
					
					gs_signalQueue[*g_threadId].reserve(idx + 1);
					foreach (i; gs_signalQueue[*g_threadId].length .. gs_signalQueue[*g_threadId].capacity) {
						gs_signalQueue[*g_threadId].insertBack(cast(AsyncSignal)null);
					}
					
				}

				gs_signalQueue[*g_threadId][idx] = cast(AsyncSignal) ctxt;
			}
		} catch {}

		return idx;
	}

	// called on kill
	void destroyIndex(shared AsyncSignal ctxt) {
		try {
			g_idxAvailable.insert(ctxt.id);
			synchronized (gs_queueMutex.writer) {
				gs_signalQueue[*g_threadId][ctxt.id] = null;
			}
		}
		catch (Exception e) {
			assert(false, "Error destroying index: " ~ e.msg);
		}
	}
}

mixin template TCPConnectionMixins() {
	
	private CleanupData m_impl;
	
	struct CleanupData {
		EventInfo* evInfo;
		bool connected;
		bool disconnecting;
	}
	
	@property bool* disconnecting() {
		return &m_impl.disconnecting;
	}
	
	@property bool* connected() {
		return &m_impl.connected;
	}

	@property EventInfo* evInfo() {
		return m_impl.evInfo;
	}
	
	@property void evInfo(EventInfo* info) {
		m_impl.evInfo = info;
	}
	
}

mixin template EvInfoMixins() {
	
	private CleanupData m_impl;
	
	struct CleanupData {
		EventInfo* evInfo;
	}
	
	@property EventInfo* evInfo() {
		return m_impl.evInfo;
	}
	
	@property void evInfo(EventInfo* info) {
		m_impl.evInfo = info;
	}
}



union EventObject {
	TCPAcceptHandler tcpAcceptHandler;
	TCPEventHandler tcpEvHandler;
	TimerHandler timerHandler;
	UDPHandler udpHandler;
	NotifierHandler notifierHandler;
}

enum EventType : char {
	TCPAccept,
	TCPTraffic,
	UDPSocket,
	Notifier,
	Signal,
	Timer
}

struct EventInfo {
	fd_t fd;
	EventType evType;
	EventObject evObj;
	ushort owner;
}

/**
		Represents a network/socket address. (taken from vibe.core.net)
*/
public struct NetworkAddress {
	import std.c.linux.socket : sockaddr, sockaddr_in, sockaddr_in6, AF_INET, AF_INET6;
	private union {
		sockaddr addr;
		sockaddr_in addr_ip4;
		sockaddr_in6 addr_ip6;
	}
	
	/** Family (AF_) of the socket address.
		*/
	@property ushort family() const pure nothrow { return addr.sa_family; }
	/// ditto
	@property void family(ushort val) pure nothrow { addr.sa_family = cast(ubyte)val; }
	
	/** The port in host byte order.
		*/
	@property ushort port()
	const pure nothrow {
		switch (this.family) {
			default: assert(false, "port() called for invalid address family.");
			case AF_INET: return ntoh(addr_ip4.sin_port);
			case AF_INET6: return ntoh(addr_ip6.sin6_port);
		}
	}
	/// ditto
	@property void port(ushort val)
	pure nothrow {
		switch (this.family) {
			default: assert(false, "port() called for invalid address family.");
			case AF_INET: addr_ip4.sin_port = hton(val); break;
			case AF_INET6: addr_ip6.sin6_port = hton(val); break;
		}
	}
	
	/** A pointer to a sockaddr struct suitable for passing to socket functions.
		*/
	@property inout(sockaddr)* sockAddr() inout pure nothrow { return &addr; }
	
	/** Size of the sockaddr struct that is returned by sockAddr().
		*/
	@property int sockAddrLen()
	const pure nothrow {
		switch (this.family) {
			default: assert(false, "sockAddrLen() called for invalid address family.");
			case AF_INET: return addr_ip4.sizeof;
			case AF_INET6: return addr_ip6.sizeof;
		}
	}
	
	@property inout(sockaddr_in)* sockAddrInet4() inout pure nothrow
	in { assert (family == AF_INET); }
	body { return &addr_ip4; }
	
	@property inout(sockaddr_in6)* sockAddrInet6() inout pure nothrow
	in { assert (family == AF_INET6); }
	body { return &addr_ip6; }
	
	/** Returns a string representation of the IP address
		*/
	string toAddressString()
	const {
		import std.array : appender;
		import std.string : format;
		import std.format : formattedWrite;
		
		switch (this.family) {
			default: assert(false, "toAddressString() called for invalid address family.");
			case AF_INET:
				ubyte[4] ip = (cast(ubyte*)&addr_ip4.sin_addr.s_addr)[0 .. 4];
				return format("%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
			case AF_INET6:
				ubyte[16] ip = addr_ip6.sin6_addr.s6_addr;
				auto ret = appender!string();
				ret.reserve(40);
				foreach (i; 0 .. 8) {
					if (i > 0) ret.put(':');
					ret.formattedWrite("%x", bigEndianToNative!ushort(cast(ubyte[2])ip[i*2 .. i*2+2]));
				}
				return ret.data;
		}
	}
	
	/** Returns a full string representation of the address, including the port number.
		*/
	string toString()
	const {
		
		import std.string : format;
		
		auto ret = toAddressString();
		switch (this.family) {
			default: assert(false, "toString() called for invalid address family.");
			case AF_INET: return ret ~ format(":%s", port);
			case AF_INET6: return format("[%s]:%s", ret, port);
		}
	}
	
}

private pure nothrow {
	import std.bitmanip;
	
	ushort ntoh(ushort val)
	{
		version (LittleEndian) return swapEndian(val);
		else version (BigEndian) return val;
		else static assert(false, "Unknown endianness.");
	}
	
	ushort hton(ushort val)
	{
		version (LittleEndian) return swapEndian(val);
		else version (BigEndian) return val;
		else static assert(false, "Unknown endianness.");
	}
}
