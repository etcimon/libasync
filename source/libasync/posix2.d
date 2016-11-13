module libasync.posix2;

version (Posix):

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
			static if (LOG) log("Close socket");
			close(fd);
			return 0;
		}

		/// Enable Nagel's algorithm if specified
		if (ctxt.noDelay) {
			if (!setOption(fd, TCPOption.NODELAY, true)) {
				static if (LOG) try log("Closing connection"); catch {}
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

	fd_t run(AsyncUDSConnection ctxt)
	in { assert(ctxt.socket == fd_t.init, "UDS Connection is active. Use another instance."); }
	body {
		m_status = StatusInfo.init;
		import libasync.internals.socket_compat : socket, connect, SOCK_STREAM, AF_UNIX;
		import core.sys.posix.unistd : close;

		auto fd = ctxt.preInitializedSocket;
		if (fd == fd_t.init) {
			fd = socket(AF_UNIX, SOCK_STREAM, 0);
		}

		if (catchError!"run AsyncUDSConnection"(fd)) {
			return 0;
		}

		// Inbound sockets are already connected
		if (ctxt.inbound) return fd;

		/// Make sure the socket doesn't block on recv/send
		if (!setNonBlock(fd)) {
			static if (LOG) log("Close socket");
			close(fd);
			return 0;
		}

		/// Start the connection
		auto err = connect(fd, ctxt.peer.name, ctxt.peer.nameLen);
		if (catchError!"connect"(err)) {
			close(fd);
			return 0;
		}

		return fd;
	}

	fd_t run(AsyncUDSListener ctxt)
	in {
		assert(ctxt.socket == fd_t.init, "UDS Listener already bound. Please run another instance.");
		assert(ctxt.local !is UnixAddress.init, "No locally binding address specified. Use AsyncUDSListener.local = new UnixAddress(*)");
	}
	body {
		import libasync.internals.socket_compat : socket, bind, listen, SOCK_STREAM, AF_UNIX, SOMAXCONN;
		import core.sys.posix.unistd : close, unlink;
		import core.sys.posix.sys.un : sockaddr_un;

		int err;
		m_status = StatusInfo.init;

		if (ctxt.unlinkFirst) {
			import core.stdc.errno : errno, ENOENT;
			err = unlink(cast(char*) (cast(sockaddr_un*) ctxt.local.name).sun_path);
			if (err == -1 && errno != ENOENT) {
				if (catchError!"unlink"(err)) {}
				return 0;
			}
		}

		auto fd = ctxt.socket;
		if (fd == fd_t.init) {
			fd = socket(AF_UNIX, SOCK_STREAM, 0);
		}

		if (catchError!"run AsyncUDSAccept"(fd)) {
			return 0;
		}

		/// Make sure the socket returns instantly when calling listen()
		if (!setNonBlock(fd)) {
			static if (LOG) log("Close socket");
			close(fd);
			return 0;
		}

		/// Bind and listen to socket
		err = bind(fd, ctxt.local.name, ctxt.local.nameLen);
		if (catchError!"bind"(err)) {
			static if (LOG) log("Close socket");
			close(fd);
			return 0;
		}

		err = listen(fd, SOMAXCONN);
		if (catchError!"listen"(err)) {
			static if (LOG) log("Close socket");
			close(fd);
			return 0;
		}

		return fd;
	}

	fd_t run(AsyncSocket ctxt)
	{
		import core.sys.posix.unistd : close;
		import libasync.internals.socket_compat : socket;

		m_status = StatusInfo.init;

		auto fd = ctxt.preInitializedHandle;

		if (fd == INVALID_SOCKET) {
			fd = socket(ctxt.info.domain, ctxt.info.type, ctxt.info.protocol);
		}

		if (catchError!"socket"(fd)) {
			.error("Failed to create socket: ", error);
			return INVALID_SOCKET;
		}

		if (!setNonBlock(fd)) {
			.error("Failed to set socket non-blocking");
			close(fd);
			return INVALID_SOCKET;
		}

		import core.sys.posix.unistd;

		EventObject eventObject;
		eventObject.socket = ctxt;
		EventInfo* eventInfo = assumeWontThrow(ThreadMem.alloc!EventInfo(fd, EventType.Socket, eventObject, m_instanceId));

		ctxt.evInfo = eventInfo;
		nothrow auto cleanup() {
			assumeWontThrow(ThreadMem.free(eventInfo));
			ctxt.evInfo = null;
			// socket must be closed by the caller
			return INVALID_SOCKET;
		}

		fd_t err;
		static if (EPOLL)
		{
			epoll_event osEvent;
			osEvent.data.ptr = eventInfo;
			osEvent.events = EPOLLET | EPOLLIN | EPOLLOUT | EPOLLERR | EPOLLHUP | EPOLLRDHUP;
			err = epoll_ctl(m_epollfd, EPOLL_CTL_ADD, fd, &osEvent);
			if (catchError!"epoll_ctl"(err)) {
				return cleanup();
			}
		}
		else /* if KQUEUE */
		{
			kevent_t[2] osEvent;
			EV_SET(&(osEvent[0]), fd, EVFILT_READ, EV_ADD | EV_ENABLE | EV_CLEAR, 0, 0, eventInfo);
			EV_SET(&(osEvent[1]), fd, EVFILT_WRITE, EV_ADD | EV_ENABLE | EV_CLEAR, 0, 0, eventInfo);
			err = kevent(m_kqueuefd, &(osEvent[0]), 2, null, 0, null);
			if (catchError!"kevent_add_udp"(err)) {
				return cleanup();
			}
		}

		return fd;
	}

	import libasync.internals.socket_compat : sockaddr, socklen_t;
	bool bind(AsyncSocket ctxt, sockaddr* addr, socklen_t addrlen)
	{
		import libasync.internals.socket_compat : bind;

		auto err = bind(ctxt.handle, addr, addrlen);
		if (catchError!"bind"(err)) {
			.error("Failed to bind socket: ", error);
			assumeWontThrow(ThreadMem.free(ctxt.evInfo));
			ctxt.evInfo = null;
			return false;
		}

		return true;
	}

	bool connect(AsyncSocket ctxt, sockaddr* addr, socklen_t addrlen)
	{
		import libasync.internals.socket_compat : connect;

		auto err = connect(ctxt.handle, addr, addrlen);
		if (catchErrorsEq!"connect"(err, [ tuple(cast(fd_t) SOCKET_ERROR, EPosix.EINPROGRESS, Status.ASYNC) ])) {
			return true;
		} else if (catchError!"connect"(err)) {
			.error("Failed to connect socket: ", error);
			assumeWontThrow(ThreadMem.free(ctxt.evInfo));
			ctxt.evInfo = null;
			return false;
		}

		return true;
	}

	bool listen(AsyncSocket ctxt, int backlog)
	{
		import libasync.internals.socket_compat : listen;

		auto err = listen(ctxt.handle, backlog);
		if (catchError!"bind"(err)) {
			.error("Failed to listen on socket: ", error);
			assumeWontThrow(ThreadMem.free(ctxt.evInfo));
			ctxt.evInfo = null;
			return false;
		}

		return true;
	}

	bool kill(AsyncSocket ctxt, bool forced = false) {
		m_status = StatusInfo.init;

		import core.sys.posix.unistd : close;

		auto fd = ctxt.resetHandle();

		static if (EPOLL)
		{
			epoll_event osEvent = void;
			epoll_ctl(m_epollfd, EPOLL_CTL_DEL, fd, &osEvent);
		}
		else /* if KQUEUE */
		{
			kevent_t osEvent;
			EV_SET(&osEvent, fd, EVFILT_READ, EV_DELETE | EV_DISABLE, 0, 0, null);
			EV_SET(&osEvent, fd, EVFILT_WRITE, EV_DELETE | EV_DISABLE, 0, 0, null);
		}

		if (ctxt.connectionOriented && ctxt.passive) {
			foreach (request; m_completedSocketAccepts) if (request.socket is ctxt) {
				m_completedSocketAccepts.removeFront();
				auto socket = request.socket;
				auto peer = request.onComplete(request.peer, request.family, socket.info.type, socket.info.protocol);
				assumeWontThrow(AsyncAcceptRequest.free(request));
				if (!peer.run) return false;
			}
		}

		if (!ctxt.passive) {
			foreach (request; m_completedSocketReceives) if (request.socket is ctxt) {
				m_completedSocketReceives.removeFront();
				if (request.message) {
					assumeWontThrow(request.onComplete.get!0)(request.message.transferred);
					assumeWontThrow(NetworkMessage.free(request.message));
				} else {
					assumeWontThrow(request.onComplete.get!1)();
				}
				assumeWontThrow(AsyncReceiveRequest.free(request));
			}

			foreach (request; m_completedSocketSends) if (request.socket is ctxt) {
				m_completedSocketSends.removeFront();
				request.onComplete();
				assumeWontThrow(NetworkMessage.free(request.message));
				assumeWontThrow(AsyncSendRequest.free(request));
			}
		}

		foreach (request; ctxt.m_pendingReceives) {
			ctxt.m_pendingReceives.removeFront();
			if (request.message) assumeWontThrow(NetworkMessage.free(request.message));
			assumeWontThrow(AsyncReceiveRequest.free(request));
		}

		foreach (request; ctxt.m_pendingSends) {
			ctxt.m_pendingSends.removeFront();
			assumeWontThrow(NetworkMessage.free(request.message));
			assumeWontThrow(AsyncSendRequest.free(request));
		}

		if (ctxt.connectionOriented && !ctxt.passive && ctxt.connected) {
			bool has_socket = fd != INVALID_SOCKET;
			ctxt.disconnecting = true;

			if (forced) {
				ctxt.connected = false;
				ctxt.disconnecting = false;
				if (ctxt.evInfo !is null) {
					assumeWontThrow(ThreadMem.free(ctxt.evInfo));
					ctxt.evInfo = null;
				}
			}

			return has_socket ? closeSocket(fd, true, forced) : true;
		}

		fd_t err = close(fd);
		if (catchError!"socket close"(err)) {
			return false;
		}

		if (ctxt.evInfo !is null) {
			assumeWontThrow(ThreadMem.free(ctxt.evInfo));
			ctxt.evInfo = null;
		}

		return true;
	}

	bool run(AsyncEvent ctxt, EventHandler del)
	{
		fd_t fd = ctxt.id;
		import libasync.internals.socket_compat : bind;
		import core.sys.posix.unistd;

		fd_t err;

		EventObject eo;
		eo.eventHandler = del;
		EventInfo* ev;
		try ev = ThreadMem.alloc!EventInfo(fd, EventType.Event, eo, m_instanceId);
		catch (Exception e){ assert(false, "Allocation error"); }
		ctxt.evInfo = ev;
		nothrow bool closeAll() {
			try ThreadMem.free(ev);
			catch(Exception e){ assert(false, "Failed to free resources"); }
			ctxt.evInfo = null;
			// fd must be closed by the caller if return false
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
		}
		else /* if KQUEUE */
		{
			kevent_t[2] _event;
			EV_SET(&(_event[0]), fd, EVFILT_READ, EV_ADD | EV_ENABLE | EV_CLEAR, 0, 0, ev);
			EV_SET(&(_event[1]), fd, EVFILT_WRITE, EV_ADD | EV_ENABLE | EV_CLEAR, 0, 0, ev);
			err = kevent(m_kqueuefd, &(_event[0]), 2, null, 0, null);
			if (catchError!"kevent_add_udp"(err))
				return closeAll();

		}
		return true;
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
					static if (LOG) log("Close socket");
					close(fd);
					return 0;
				}
				if (!setOption(fd, TCPOption.REUSEPORT, true)) {
					static if (LOG) log("Close socket");
					close(fd);
					return 0;
				}
			}

			/// Make sure the socket returns instantly when calling listen()
			if (!setNonBlock(fd)) {
				static if (LOG) log("Close socket");
				close(fd);
				return 0;
			}

			// todo: defer accept

			/// Automatically starts connections with noDelay if specified
			if (ctxt.noDelay) {
				if (!setOption(fd, TCPOption.NODELAY, true)) {
					static if (LOG) try log("Closing connection"); catch {}
					close(fd);
					return 0;
				}
			}

		} catch { assert(false, "Error in synchronized listener starter"); }

		/// Setup the event polling
		if (!initTCPListener(fd, ctxt, del, reusing)) {
			static if (LOG) log("Close socket");
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

		static if (LOG) try log("Address: " ~ ctxt.local.toString()); catch {}

		if (fd == fd_t.init)
			fd = socket(cast(int)ctxt.local.family, SOCK_DGRAM, IPPROTO_UDP);


		if (catchError!("run AsyncUDPSocket")(fd))
			return 0;

		if (!setNonBlock(fd)) {
			close(fd);
			return 0;
		}

		if (!initUDPSocket(fd, ctxt, del)) {
			close(fd);
			return 0;
		}

		static if (LOG) try log("UDP Socket started FD#" ~ fd.to!string);
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
			try evinfo = ThreadMem.alloc!EventInfo(fd, evtype, eobj, m_instanceId);
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
				try evinfo = ThreadMem.alloc!EventInfo(fd, evtype, eobj, m_instanceId);
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
				try evinfo = ThreadMem.alloc!EventInfo(fd, evtype, eobj, m_instanceId);
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
			ushort flags_ = EV_ADD | EV_ENABLE;
			//if (ctxt.oneShot)
			//	flags_ |= EV_CLEAR;

			// www.khmere.com/freebsd_book/html/ch06.html - EV_CLEAR set internally
			EV_SET(&_event, fd, EVFILT_TIMER, flags_, 0, msecs + 30, cast(void*) evinfo);

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

			try evinfo = ThreadMem.alloc!EventInfo(fd, evtype, eobj, m_instanceId);
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

			try evinfo = ThreadMem.alloc!EventInfo(fd, evtype, eobj, m_instanceId);
			catch (Exception e) {
				assert(false, "Failed to allocate resources: " ~ e.msg);
			}
			ctxt.evInfo = evinfo;
			try m_watchers[fd] = evinfo; catch {}

			try m_changes[fd] = ThreadMem.alloc!(Array!DWChangeInfo)();
			catch (Exception e) {
				assert(false, "Failed to allocate resources: " ~ e.msg);
			}

			/// events will be created in watch()

			return fd;

		}
	}

	AsyncUDSConnection accept(AsyncUDSListener ctxt) {
		import core.stdc.errno : errno, EAGAIN, EWOULDBLOCK;
		import libasync.internals.socket_compat : accept;

		auto clientSocket = accept(ctxt.socket, null, null);
		if (clientSocket == -1 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
			// No more new incoming connections
			return null;
		} else if (catchError!".accept"(clientSocket)) {
			// An error occured
			return null;
		}

		// Allocate a new connection handler
		AsyncUDSConnection conn;
		try conn = ThreadMem.alloc!AsyncUDSConnection(ctxt.m_evLoop, clientSocket);
		catch (Exception e){ assert(false, "Allocation failure"); }
		conn.inbound = true;

		return conn;
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
				ThreadMem.free(ctxt.evInfo);
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

				ThreadMem.free(m_changes[ctxt.fd]);
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
		static if (LOG) log("Kill socket");
		m_status = StatusInfo.init;
		fd_t fd = ctxt.socket;
		bool has_socket = fd > 0;
		ctxt.disconnecting = true;
		if (forced) {
			ctxt.connected = false;
			ctxt.disconnecting = false;
			if (ctxt.evInfo) {
				try ThreadMem.free(ctxt.evInfo);
				catch { assert(false, "Failed to free resources"); }
				ctxt.evInfo = null;
			}
			if (ctxt.inbound) try ThreadMem.free(ctxt);
			catch (Throwable t) { assert(false, "Failed to free resources for context " ~ (cast(void*)ctxt).to!string ~ ": " ~ t.to!string); }
		}
		return has_socket ? closeSocket(fd, true, forced) : true;
	}

	bool kill(AsyncTCPListener ctxt)
	{
		static if (LOG) log("Kill listener");
		m_status = StatusInfo.init;
		nothrow void cleanup() {
			try ThreadMem.free(ctxt.evInfo);
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

			try ThreadMem.free(ctxt.evInfo);
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

			try ThreadMem.free(ctxt.evInfo);
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
				try ThreadMem.free(ctxt.evInfo);
				catch (Exception e) { assert(false, "Failed to free resources: " ~ e.msg); }
				ctxt.evInfo = null;
			}

		}
		else /* if KQUEUE */
		{
			scope(exit)
				destroyIndex(ctxt);

			if (ctxt.evInfo) {
				try ThreadMem.free(ctxt.evInfo);
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

		try ThreadMem.free(ctxt.evInfo);
		catch (Exception e){
			assert(false, "Failed to free resources: " ~ e.msg);
		}
		ctxt.evInfo = null;
		return true;
	}

	bool kill(AsyncEvent ctxt, bool forced = false) {
		import core.sys.posix.unistd : close;

		static if (LOG) log("Kill event");
		m_status = StatusInfo.init;
		fd_t fd = ctxt.id;

		if (ctxt.stateful) {
			bool has_socket = fd > 0;
			ctxt.disconnecting = true;

			if (forced) {
				ctxt.connected = false;
				ctxt.disconnecting = false;
				if (ctxt.evInfo) {
					try ThreadMem.free(ctxt.evInfo);
					catch (Exception e) {
						assert(false, "Failed to free resources: " ~ e.msg);
					}
					ctxt.evInfo = null;
				}
			}

			return has_socket ? closeSocket(fd, true, forced) : true;
		}

		fd_t err = close(fd);
		if (catchError!"event close"(err))
			return false;

		if (ctxt.evInfo) {
			try ThreadMem.free(ctxt.evInfo);
			catch (Exception e) {
				assert(false, "Failed to free resources: " ~ e.msg);
			}
			ctxt.evInfo = null;
		}

		return true;
	}

}
