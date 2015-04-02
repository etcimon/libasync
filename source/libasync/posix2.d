module libasync.posix2;

// workaround for IDE indent bug on too big files
mixin template RunKill()
{

	fd_t run(AsyncTCPConnection ctxt, TCPEventHandler del)
	in { assert(ctxt.socket == fd_t.init, "TCP Connection is active. Use another instance."); }
	body {
		m_status = StatusInfo.init;
		import libasync.internals.socket_compat : socket, SOCK_STREAM, IPPROTO_TCP;
		import core.sys.posix.unistd : close;
		fd_t fd = ctxt.preInitializedSocket;

		if (fd == fd_t.init)
			fd = socket(cast(int)ctxt.peer.family, SOCK_STREAM, IPPROTO_TCP);
		
		if (catchError!("run AsyncTCPConnection")(fd)) 
			return 0;
		
		/// Make sure the socket doesn't block on recv/send
		if (!setNonBlock(fd)) {
			log("Close socket");
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
		
		return fd;
		
	}
	
	fd_t run(AsyncTCPListener ctxt, TCPAcceptHandler del)
	in { 
		//assert(ctxt.socket == fd_t.init, "TCP Listener already bound. Please run another instance."); 
		assert(ctxt.local.addr !is typeof(ctxt.local.addr).init, "No locally binding address specified. Use AsyncTCPListener.local = EventLoop.resolve*"); 
	}
	body {
		m_status = StatusInfo.init;
		import libasync.internals.socket_compat : socket, SOCK_STREAM, socklen_t, setsockopt, SOL_SOCKET, SO_REUSEADDR, IPPROTO_TCP;
		import core.sys.posix.unistd : close;
		import core.sync.mutex;
		__gshared Mutex g_mtx;
		fd_t fd = ctxt.socket;
		bool reusing = true;
		try if (fd == 0) {
			reusing = false;
			/// Create the listening socket
			synchronized(g_mutex) {
				fd = socket(cast(int)ctxt.local.family, SOCK_STREAM, IPPROTO_TCP);
				if (catchError!("run AsyncTCPAccept")(fd))
					return 0;
				/// Allow multiple threads to listen on this address
				if (!setOption(fd, TCPOption.REUSEADDR, true)) {
					log("Close socket");
					close(fd);
					return 0;
				}
			} 

			/// Make sure the socket returns instantly when calling listen()
			if (!setNonBlock(fd)) {
				log("Close socket");
				close(fd);
				return 0;
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

		} catch { assert(false, "Error in synchronized listener starter"); }

		/// Setup the event polling
		if (!initTCPListener(fd, ctxt, del, reusing)) {
			log("Close socket");
			close(fd);
			return 0;
		}


		return fd;
		
	}
	
	fd_t run(AsyncUDPSocket ctxt, UDPHandler del) {
		m_status = StatusInfo.init;
		
		import libasync.internals.socket_compat : socket, SOCK_DGRAM, IPPROTO_UDP;
		import core.sys.posix.unistd;
		fd_t fd = ctxt.preInitializedSocket;

		try log("Address: " ~ ctxt.local.toString()); catch {}

		if (fd == fd_t.init)
			fd = socket(cast(int)ctxt.local.family, SOCK_DGRAM, IPPROTO_UDP);


		if (catchError!("run AsyncUDPSocket")(fd))
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
			
			return cast(fd_t) (__libc_current_sigrtmin());
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
			import core.sys.posix.time : itimerspec, CLOCK_REALTIME;
			
			fd_t fd = ctxt.id;
			itimerspec its;
			
			its.it_value.tv_sec = cast(typeof(its.it_value.tv_sec)) timeout.split!("seconds", "nsecs")().seconds;
			its.it_value.tv_nsec = cast(typeof(its.it_value.tv_nsec)) timeout.split!("seconds", "nsecs")().nsecs;
			if (!ctxt.oneShot)
			{
				its.it_interval.tv_sec = its.it_value.tv_sec;
				its.it_interval.tv_nsec = its.it_value.tv_nsec;
				
			}
			
			if (fd == fd_t.init) {
				fd = timerfd_create(CLOCK_REALTIME, 0);
				if (catchError!"timer_create"(fd))
					return 0;
			}
			int err = timerfd_settime(fd, 0, &its, null);
			
			if (catchError!"timer_settime"(err))
				return 0;
			epoll_event _event;

			EventType evtype;			
			evtype = EventType.Timer;
			EventObject eobj;
			eobj.timerHandler = del;
			
			EventInfo* evinfo;
			
			if (!ctxt.evInfo) {
				try evinfo = FreeListObjectAlloc!EventInfo.alloc(fd, evtype, eobj, m_instanceId);
				catch (Exception e) {
					assert(false, "Failed to allocate resources: " ~ e.msg);
				}
				
				ctxt.evInfo = evinfo;
			}
			else {
				evinfo = ctxt.evInfo;
				evinfo.evObj = eobj;
			}
			_event.events |= EPOLLIN | EPOLLET;
			_event.data.ptr = evinfo;
			if (ctxt.id > 0) {
				err = epoll_ctl(m_epollfd, EPOLL_CTL_DEL, ctxt.id, null); 
				
				if (catchError!"epoll_ctl"(err))
					return fd_t.init;
			}
			err = epoll_ctl(m_epollfd, EPOLL_CTL_ADD, fd, &_event); 
			
			if (catchError!"timer_epoll_add"(err))
				return 0;
			return fd;
		}
		else /* if KQUEUE */
		{
			fd_t fd = ctxt.id;
			
			if (ctxt.id == 0)
				fd = cast(fd_t) createIndex();
			EventType evtype;			
			evtype = EventType.Timer;
			
			EventObject eobj;
			eobj.timerHandler = del;
			
			EventInfo* evinfo;
			
			if (!ctxt.evInfo) {
				try evinfo = FreeListObjectAlloc!EventInfo.alloc(fd, evtype, eobj, m_instanceId);
				catch (Exception e) {
					assert(false, "Failed to allocate resources: " ~ e.msg);
				}
				
				ctxt.evInfo = evinfo;
			}
			else {
				evinfo = ctxt.evInfo;
				evinfo.evObj = eobj;
			}

			kevent_t _event;
			
			int msecs = cast(int) timeout.total!"msecs";
			
			// www.khmere.com/freebsd_book/html/ch06.html - EV_CLEAR set internally
			EV_SET(&_event, fd, EVFILT_TIMER, EV_ADD | EV_ENABLE, 0, msecs, cast(void*) evinfo);
			
			if (ctxt.oneShot)
				_event.flags |= EV_ONESHOT;
			
			int err = kevent(m_kqueuefd, &_event, 1, null, 0, null);
			
			if (catchError!"kevent_timer_add"(err))
				return 0;
			
			return fd;
			
		}
		
	}
	
	fd_t run(AsyncDirectoryWatcher ctxt, DWHandler del) {


		static if (EPOLL) 
		{
			import core.sys.linux.sys.inotify;
			enum IN_NONBLOCK = 0x800; // value in core.sys.linux.sys.inotify is incorrect
			assert(ctxt.fd == fd_t.init);
			int fd = inotify_init1(IN_NONBLOCK);
			if (catchError!"inotify_init1"(fd)) {
				return fd_t.init;
			}
			epoll_event _event;
			
			EventType evtype;
			
			evtype = EventType.DirectoryWatcher;
			EventObject eobj;
			eobj.dwHandler = del;
			
			EventInfo* evinfo;

			assert (!ctxt.evInfo, "Cannot run the same DirectoryWatcher again. This should have been caught earlier...");
			
			try evinfo = FreeListObjectAlloc!EventInfo.alloc(fd, evtype, eobj, m_instanceId);
			catch (Exception e) {
				assert(false, "Failed to allocate resources: " ~ e.msg);
			}
			
			ctxt.evInfo = evinfo;
			
			_event.events |= EPOLLIN;
			_event.data.ptr = evinfo;
			
			int err = epoll_ctl(m_epollfd, EPOLL_CTL_ADD, fd, &_event); 
			
			if (catchError!"epoll_ctl"(err))
				return fd_t.init;
			return fd;
		} 
		else /* if KQUEUE */ {
			static size_t id = 0;

			fd_t fd = cast(uint)++id;

			EventType evtype;
			
			evtype = EventType.DirectoryWatcher;
			EventObject eobj;
			eobj.dwHandler = del;
			
			EventInfo* evinfo;

			assert (!ctxt.evInfo, "Cannot run the same DirectoryWatcher again. This should have been caught earlier...");

			try evinfo = FreeListObjectAlloc!EventInfo.alloc(fd, evtype, eobj, m_instanceId);
			catch (Exception e) {
				assert(false, "Failed to allocate resources: " ~ e.msg);
			}
			ctxt.evInfo = evinfo;
			try m_watchers[fd] = evinfo; catch {}

			try m_changes[fd] = FreeListObjectAlloc!(Array!DWChangeInfo).alloc();
			catch (Exception e) {
				assert(false, "Failed to allocate resources: " ~ e.msg);
			}

			/// events will be created in watch()

			return fd;

		}
	}
	
	bool kill(AsyncDirectoryWatcher ctxt) {

		static if (EPOLL) {
			import core.sys.posix.unistd : close;
			try 
			{
				Array!(Tuple!(fd_t, uint)) remove_list;
				foreach (ref const Tuple!(fd_t, uint) key, ref const DWFolderInfo info; m_dwFolders) {
					if (info.fd == ctxt.fd)
						remove_list.insertBack(key);
				}

				foreach (Tuple!(fd_t, uint) key; remove_list[]) {
					unwatch(key[0] /*fd_t*/, key[1]);
				}

				close(ctxt.fd);
				FreeListObjectAlloc!EventInfo.free(ctxt.evInfo);
				ctxt.evInfo = null;
			}
			catch (Exception e)
			{ 
				setInternalError!"Kill.DirectoryWatcher"(Status.ERROR, "Error killing directory watcher"); 
				return false;
			}

		} else /* if KQUEUE */ {
			try {
				Array!fd_t remove_list;

				foreach (ref const fd_t wd, ref const DWFolderInfo info; m_dwFolders) {
					if (info.fd == ctxt.fd)
						remove_list.insertBack(wd);
				}
				
				foreach (wd; remove_list[]) {
					unwatch(ctxt.fd, wd); // deletes all related m_dwFolders and m_dwFiles entries
				}

				FreeListObjectAlloc!(Array!DWChangeInfo).free(m_changes[ctxt.fd]);
				m_watchers.remove(ctxt.fd);	
				m_changes.remove(ctxt.fd);		
			}
			catch (Exception e) {
				setInternalError!"Kill.DirectoryWatcher"(Status.ERROR, "Error killing directory watcher"); 
				return false;
			}
		}
		return true;
	}
	
	bool kill(AsyncTCPConnection ctxt, bool forced = false)
	{
		log("Kill socket");
		m_status = StatusInfo.init;
		fd_t fd = ctxt.socket;
		if (ctxt.connected) {
			ctxt.disconnecting = true;
			if (forced) {
				if (ctxt.evInfo)
					try FreeListObjectAlloc!EventInfo.free(ctxt.evInfo);
					catch { assert(false, "Failed to free resources"); }
				try FreeListObjectAlloc!AsyncTCPConnection.free(ctxt);
				catch { assert(false, "Failed to free resources"); }
			}
			return closeSocket(fd, true, forced);
		}
		else {
			ctxt.disconnecting = true;
			if (forced) {
				if (ctxt.evInfo)
					try FreeListObjectAlloc!EventInfo.free(ctxt.evInfo);
					catch { assert(false, "Failed to free resources"); }
				try FreeListObjectAlloc!AsyncTCPConnection.free(ctxt);
				catch { assert(false, "Failed to free resources"); }
			}
			return true;
		}
	}

	bool kill(AsyncTCPListener ctxt)
	{
		log("Kill listener");
		m_status = StatusInfo.init;
		nothrow void cleanup() {
			try FreeListObjectAlloc!EventInfo.free(ctxt.evInfo);
			catch { assert(false, "Failed to free resources"); }
			ctxt.evInfo = null;
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
				ctxt.evInfo = null;
			}
			
		}
		else /* if KQUEUE */
		{
			scope(exit) 
				destroyIndex(ctxt);
			
			if (ctxt.evInfo) {
				try FreeListObjectAlloc!EventInfo.free(ctxt.evInfo);
				catch (Exception e) { assert(false, "Failed to free resources: " ~ e.msg); }
				ctxt.evInfo = null;
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
		ctxt.evInfo = null;
		return true;
	}

}
