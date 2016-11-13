module libasync.windows;

version (Windows):

import core.atomic;
import core.thread : Fiber;
import libasync.types;
import std.container : Array;
import std.string : toStringz;
import std.conv : to;
import std.datetime : Duration, msecs, seconds;
import std.algorithm : min;
import std.exception;
import libasync.internals.win32;
import libasync.internals.logging;
import std.traits : isIntegral;
import std.typecons : Tuple, tuple;
import std.utf : toUTFz;
import core.sync.mutex;
import libasync.events;
import memutils.utils;
import memutils.hashmap;
import memutils.vector;
pragma(lib, "ws2_32");
pragma(lib, "ole32");
alias fd_t = SIZE_T;
alias error_t = EWIN;

//todo :  see if new connections with SO_REUSEADDR are evenly distributed between threads


package struct EventLoopImpl {
	pragma(msg, "Using Windows message-based notifications and alertable IO for events");

private:
	HashMap!(fd_t, TCPAcceptHandler) m_connHandlers; // todo: Change this to an array
	HashMap!(fd_t, TCPEventHandler) m_tcpHandlers;
	HashMap!(fd_t, TimerHandler) m_timerHandlers;
	HashMap!(fd_t, UDPHandler) m_udpHandlers;
	HashMap!(fd_t, DWHandlerInfo) m_dwHandlers; // todo: Change this to an array too
	HashMap!(uint, DWFolderWatcher) m_dwFolders;
	HashMap!(fd_t, tcp_keepalive)* kcache;
	~this() { kcache.destroy(); }
nothrow:
private:
	struct TimerCache {
		TimerHandler cb;
		fd_t fd;
	}
	TimerCache m_timer;

	EventLoop m_evLoop;
	bool m_started;
	wstring m_window;
	HWND m_hwnd;
	DWORD m_threadId;
	ushort m_instanceId;
	StatusInfo m_status;
	error_t m_error = EWIN.WSA_OK;
	__gshared Mutex gs_mtx;

	HANDLE[] m_waitObjects;
	AsyncOverlapped*[AsyncSocket] m_pendingConnects;
	bool[AsyncOverlapped*] m_pendingAccepts;

	@property HANDLE pendingConnectEvent()
	{ return m_waitObjects[0]; }

	@property HANDLE pendingAcceptEvent()
	{ return m_waitObjects[1]; }

	AsyncAcceptRequest.Queue  m_completedSocketAccepts;
	AsyncReceiveRequest.Queue m_completedSocketReceives;
	AsyncSendRequest.Queue    m_completedSocketSends;
package:
	@property bool started() const {
		return m_started;
	}
	bool init(EventLoop evl)
	in { assert(!m_started); }
	body
	{
		try if (!gs_mtx)
			gs_mtx = new Mutex; catch (Throwable) {}
		static ushort j;
		assert (j == 0, "Current implementation is only tested with 1 event loop per thread. There are known issues with signals on linux.");
		j += 1;
		m_status = StatusInfo.init;

		import core.thread;
		//try Thread.getThis().priority = Thread.PRIORITY_MAX;
		//catch (Exception e) { assert(false, "Could not set thread priority"); }
		SetThreadPriority(GetCurrentThread(), 31);
		m_evLoop = evl;
		shared static ushort i;
		m_instanceId = i;
		core.atomic.atomicOp!"+="(i, cast(ushort) 1);
		wstring inststr;
		import std.conv : to;
		try { inststr = m_instanceId.to!wstring; }
		catch (Exception e) {
			return false;
		}
		m_window = "VibeWin32MessageWindow" ~ inststr;
		wstring classname = "VibeWin32MessageWindow" ~ inststr;

		LPCWSTR wnz;
		LPCWSTR clsn;
		try {
			wnz = cast(LPCWSTR) m_window.toUTFz!(immutable(wchar)*);
			clsn = cast(LPCWSTR) classname.toUTFz!(immutable(wchar)*);
		} catch (Exception e) {
			setInternalError!"toUTFz"(Status.ERROR, e.msg);
			return false;
		}

		m_threadId = GetCurrentThreadId();
		WNDCLASSW wc;
		wc.lpfnWndProc = &wndProc;
		wc.lpszClassName = clsn;
		RegisterClassW(&wc);
		m_hwnd = CreateWindowW(wnz, clsn, 0, 0, 0, 385, 375, HWND_MESSAGE,
		                       cast(HMENU) null, null, null);
		static if (LOG) try log("Window registered: " ~ m_hwnd.to!string); catch (Throwable) {}
		auto ptr = cast(ULONG_PTR)cast(void*)&this;
		SetWindowLongPtrA(m_hwnd, GWLP_USERDATA, ptr);
		assert( cast(EventLoopImpl*)cast(void*)GetWindowLongPtrA(m_hwnd, GWLP_USERDATA) is &this );
		WSADATA wd;
		m_error = cast(error_t) WSAStartup(0x0202, &wd);
		if (m_error == EWIN.WSA_OK)
			m_status.code = Status.OK;
		else {
			m_status.code = Status.ABORT;
			static if(LOG) log(m_status);
			return false;
		}
		assert(wd.wVersion == 0x0202);

		auto dummySocket = socket(AF_INET6, SOCK_STREAM, 0);
		if (dummySocket == INVALID_SOCKET) return false;
		scope (exit) closesocket(dummySocket);

		DWORD bytesReturned;

		if (WSAIoctl(dummySocket,
		             SIO_GET_EXTENSION_FUNCTION_POINTER,
		             &WSAID_ACCEPTEX, GUID.sizeof,
		             &AcceptEx, AcceptEx.sizeof,
		             &bytesReturned,
		             null, null) == SOCKET_ERROR) {
			m_error = WSAGetLastErrorSafe();
			m_status.code = Status.ABORT;
			return false;
		}

		if (WSAIoctl(dummySocket,
		             SIO_GET_EXTENSION_FUNCTION_POINTER,
		             &WSAID_GETACCEPTEXSOCKADDRS, GUID.sizeof,
		             &GetAcceptExSockaddrs, GetAcceptExSockaddrs.sizeof,
		             &bytesReturned,
		             null, null) == SOCKET_ERROR) {
			m_error = WSAGetLastErrorSafe();
			m_status.code = Status.ABORT;
			return false;
		}

		if (WSAIoctl(dummySocket,
		             SIO_GET_EXTENSION_FUNCTION_POINTER,
		             &WSAID_CONNECTEX, GUID.sizeof,
		             &ConnectEx, ConnectEx.sizeof,
		             &bytesReturned,
		             null, null) == SOCKET_ERROR) {
			m_error = WSAGetLastErrorSafe();
			m_status.code = Status.ABORT;
			return false;
		}

		if (WSAIoctl(dummySocket,
		             SIO_GET_EXTENSION_FUNCTION_POINTER,
		             &WSAID_DISCONNECTEX, GUID.sizeof,
		             &DisconnectEx, DisconnectEx.sizeof,
		             &bytesReturned,
		             null, null) == SOCKET_ERROR) {
			m_error = WSAGetLastErrorSafe();
			m_status.code = Status.ABORT;
			return false;
		}

		// Event for pending ConnectEx requests
		m_waitObjects ~= CreateEvent(null, false, false, null);
		// Event for pending AcceptEx requests
		m_waitObjects ~= CreateEvent(null, false, false, null);

		m_started = true;
		return true;
	}

	// todo: find where to call this
	void exit() {
		cast(void)PostThreadMessageW(m_threadId, WM_QUIT, 0, 0);
	}

	@property StatusInfo status() const {
		return m_status;
	}

	@property string error() const {
		string* ptr;
		string pv = ((ptr = (m_error in EWSAMessages)) !is null) ? *ptr : string.init;
		return pv;
	}

	bool loop(Duration timeout = 0.seconds)
	in {
		assert(Fiber.getThis() is null);
		assert(m_started);
	}
	body {
		DWORD msTimeout;

		if (timeout == -1.seconds)
			msTimeout = DWORD.max;
		else msTimeout = cast(DWORD) min(timeout.total!"msecs", DWORD.max);

		/*
		 * Waits until one or all of the specified objects are in the signaled state
		 * http://msdn.microsoft.com/en-us/library/windows/desktop/ms684245%28v=vs.85%29.aspx
		*/
		m_status = StatusInfo.init;
		DWORD signal = MsgWaitForMultipleObjectsEx(
			cast(DWORD) m_waitObjects.length,
			m_waitObjects.ptr,
			msTimeout,
			QS_ALLEVENTS,
			MWMO_ALERTABLE | MWMO_INPUTAVAILABLE		// MWMO_ALERTABLE: Wakes up to execute overlapped hEvent (i/o completion)
			// MWMO_INPUTAVAILABLE: Processes key/mouse input to avoid window ghosting
			);

		auto errors =
		[ tuple(WAIT_FAILED, Status.EVLOOP_FAILURE) ];	/* WAIT_FAILED: Failed to call MsgWait..() */

		if (signal == WAIT_TIMEOUT) {
			return true;
		}

		if (signal == WAIT_IO_COMPLETION) {
			if (m_status.code != Status.OK) return false;

			foreach (request; m_completedSocketReceives) {
				if (request.socket.receiveContinuously) {
					m_completedSocketReceives.removeFront();
					assumeWontThrow(request.onComplete.get!0)(request.message.transferred);
					if (request.socket.receiveContinuously && request.socket.alive) {
						request.message.count = 0;
						submitRequest(request);
					} else {
						assumeWontThrow(NetworkMessage.free(request.message));
						assumeWontThrow(AsyncReceiveRequest.free(request));
					}
				} else {
					m_completedSocketReceives.removeFront();
					if (request.message) {
						assumeWontThrow(request.onComplete.get!0)(request.message.transferred);
						assumeWontThrow(NetworkMessage.free(request.message));
					} else {
						assumeWontThrow(request.onComplete.get!1)();
					}
					assumeWontThrow(AsyncReceiveRequest.free(request));
				}
			}

			foreach (request; m_completedSocketSends) {
				m_completedSocketSends.removeFront();
				request.onComplete();
				assumeWontThrow(NetworkMessage.free(request.message));
				assumeWontThrow(AsyncSendRequest.free(request));
			}

			signal = MsgWaitForMultipleObjectsEx(
				cast(DWORD) m_waitObjects.length,
				m_waitObjects.ptr,
				0,
				QS_ALLEVENTS,
				MWMO_INPUTAVAILABLE // MWMO_INPUTAVAILABLE: Processes key/mouse input to avoid window ghosting
				);
			if (signal == WAIT_TIMEOUT) {
				return true;
			}
		}

		if (catchErrors!"MsgWaitForMultipleObjectsEx"(signal, errors)) {
			static if (LOG) log("Event Loop Exiting because of error");
			return false;
		}

		// Input messages
		if (signal == WAIT_OBJECT_0 + m_waitObjects.length) {
			MSG msg;
			while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE)) {
				m_status = StatusInfo.init;
				TranslateMessage(&msg);
				DispatchMessageW(&msg);

				if (m_status.code == Status.ERROR) {
					static if (LOG) log(m_status.text);
					return false;
				}
			}
			return true;
		}

		// Events
		DWORD transferred, flags;
		switch (signal - WAIT_OBJECT_0) {
			// ConnectEx completion
			case 0:
				foreach (ref pendingConnect; m_pendingConnects.byKeyValue()) {
					auto socket = pendingConnect.key;
					auto overlapped = pendingConnect.value;

					if (WSAGetOverlappedResult(socket.handle,
					                           &overlapped.overlapped,
					                           &transferred,
					                           false,
					                           &flags)) {
						m_pendingConnects.remove(socket);
						assumeWontThrow(AsyncOverlapped.free(overlapped));
						if (updateConnectContext(socket.handle)) {
							socket.handleConnect();
							return true;
						} else {
							socket.kill();
							socket.handleError();
							return false;
						}
					} else {
						m_error = WSAGetLastErrorSafe();
						if (m_error == WSA_IO_INCOMPLETE) {
							continue;
						} else {
							m_status.code = Status.ABORT;
							socket.kill();
							socket.handleError();
							return false;
						}
					}
				}
				break;
			// AcceptEx completion
			case 1:
				foreach (overlapped; cast(AsyncOverlapped*[]) m_pendingAccepts.keys) {
					auto request = overlapped.accept;
					auto socket = request.socket;

					if (WSAGetOverlappedResult(socket.handle,
					                           &overlapped.overlapped,
											   &transferred,
											   false,
											   &flags)) {
						m_pendingAccepts.remove(overlapped);
						assumeWontThrow(AsyncOverlapped.free(overlapped));
						m_completedSocketAccepts.insertBack(request);
					} else {
						m_error = WSAGetLastErrorSafe();
						if (m_error == WSA_IO_INCOMPLETE) {
							continue;
						} else {
							m_status.code = Status.ABORT;
							m_pendingAccepts.remove(overlapped);
							assumeWontThrow(AsyncOverlapped.free(overlapped));
							assumeWontThrow(AsyncAcceptRequest.free(request));
							socket.kill();
							socket.handleError();
							return false;
						}
					}
				}
				foreach (request; m_completedSocketAccepts) {
					sockaddr* localAddress, remoteAddress;
					socklen_t localAddressLength, remoteAddressLength;

					GetAcceptExSockaddrs(request.buffer.ptr,
										 0,
										 cast(DWORD) request.buffer.length / 2,
										 cast(DWORD) request.buffer.length / 2,
										 &localAddress,
										 &localAddressLength,
										 &remoteAddress,
										 &remoteAddressLength);

					m_completedSocketAccepts.removeFront();
					if (!onAccept(request.socket.handle, request, remoteAddress)) {
						return false;
					}
				}
				break;
			default:
				.warning("Unknown event was triggered: ", signal);
				break;
		}

		return true;
	}

	bool run(AsyncEvent ctxt, EventHandler del)
	{
		return true;
	}

	fd_t run(AsyncTCPListener ctxt, TCPAcceptHandler del)
	{
		m_status = StatusInfo.init;
		fd_t fd = ctxt.socket;
		bool reusing;
		if (fd == fd_t.init) {

			fd = WSASocketW(cast(int)ctxt.local.family, SOCK_STREAM, IPPROTO_TCP, null, 0, WSA_FLAG_OVERLAPPED);

			if (catchSocketError!("run AsyncTCPConnection")(fd, INVALID_SOCKET))
				return 0;

			if (!setOption(fd, TCPOption.REUSEADDR, true)) {
				closeSocket(fd, false);
				return 0;
			}
			// todo: defer accept?

			if (ctxt.noDelay) {
				if (!setOption(fd, TCPOption.NODELAY, true)) {
					closeSocket(fd, false);
					return 0;
				}
			}
		} else reusing = true;

		if (initTCPListener(fd, ctxt, reusing))
		{
			try {
				static if (LOG) log("Running listener on socket fd#" ~ fd.to!string);
				m_connHandlers[fd] = del;
				version(Distributed)ctxt.init(m_hwnd, fd);
			}
			catch (Exception e) {
				setInternalError!"m_connHandlers assign"(Status.ERROR, e.msg);
				closeSocket(fd, false);
				return 0;
			}
		}
		else
		{
			return 0;
		}


		return fd;
	}

	fd_t run(AsyncTCPConnection ctxt, TCPEventHandler del)
	in {
		assert(ctxt.socket == fd_t.init);
		assert(ctxt.peer.family != AF_UNSPEC);
	}
	body {
		m_status = StatusInfo.init;
		fd_t fd = ctxt.preInitializedSocket;

		if (fd == fd_t.init)
			fd = WSASocketW(cast(int)ctxt.peer.family, SOCK_STREAM, IPPROTO_TCP, null, 0, WSA_FLAG_OVERLAPPED);
		static if (LOG) log("Starting connection at: " ~ fd.to!string);
		if (catchSocketError!("run AsyncTCPConnection")(fd, INVALID_SOCKET))
			return 0;

		try {
			(m_tcpHandlers)[fd] = del;
		}
		catch (Exception e) {
			setInternalError!"m_tcpHandlers assign"(Status.ERROR, e.msg);
			closeSocket(fd, false);
			return 0;
		}

		nothrow void closeAll() {
			try {
				static if (LOG) log("Remove event handler for " ~ fd.to!string);
				m_tcpHandlers.remove(fd);
			}
			catch (Exception e) {
				setInternalError!"m_tcpHandlers remove"(Status.ERROR, e.msg);
			}
			closeSocket(fd, false);
		}

		if (ctxt.noDelay) {
			if (!setOption(fd, TCPOption.NODELAY, true)) {
				closeAll();
				return 0;
			}
		}

		if (!initTCPConnection(fd, ctxt)) {
			closeAll();
			return 0;
		}


		static if (LOG) try log("Client started FD#" ~ fd.to!string);
		catch (Throwable) {}
		return fd;
	}

	fd_t run(AsyncUDPSocket ctxt, UDPHandler del) {
		m_status = StatusInfo.init;
		fd_t fd = ctxt.preInitializedSocket;

		if (fd == fd_t.init)
			fd = WSASocketW(cast(int)ctxt.local.family, SOCK_DGRAM, IPPROTO_UDP, null, 0, WSA_FLAG_OVERLAPPED);

		if (catchSocketError!("run AsyncUDPSocket")(fd, INVALID_SOCKET))
			return 0;

		if (initUDPSocket(fd, ctxt))
		{
			try {
				(m_udpHandlers)[fd] = del;
			}
			catch (Exception e) {
				setInternalError!"m_udpHandlers assign"(Status.ERROR, e.msg);
				closesocket(fd);
				return 0;
			}
		}
		else return 0;

		static if (LOG) try log("UDP Socket started FD#" ~ fd.to!string);
		catch (Throwable) {}

		return fd;
	}

	fd_t run(shared AsyncSignal ctxt) {
		m_status = StatusInfo.init;
		static if (LOG) try log("Signal subscribed to: " ~ m_hwnd.to!string); catch (Throwable) {}
		return (cast(fd_t)m_hwnd);
	}

	fd_t run(AsyncNotifier ctxt) {
		m_status = StatusInfo.init;
		//static if (LOG) try log("Running signal " ~ (cast(AsyncNotifier)ctxt).to!string); catch (Throwable) {}
		return cast(fd_t) m_hwnd;
	}

	fd_t run(AsyncTimer ctxt, TimerHandler del, Duration timeout) {
		if (timeout < 0.seconds)
			timeout = 0.seconds;
		m_status = StatusInfo.init;
		fd_t timer_id = ctxt.id;
		if (timer_id == fd_t.init) {
			timer_id = createIndex();
		}
		static if (LOG) try log("Timer created: " ~ timer_id.to!string ~ " with timeout: " ~ timeout.total!"msecs".to!string ~ " msecs"); catch (Throwable) {}

		BOOL err;
		try err = cast(int)SetTimer(m_hwnd, timer_id, timeout.total!"msecs".to!uint, null);
		catch(Exception e) {
			setInternalError!"SetTimer"(Status.ERROR);
			return 0;
		}

		if (err == 0)
		{
			m_error = GetLastErrorSafe();
			m_status.code = Status.ERROR;
			m_status.text = "kill(AsyncTimer)";
			static if (LOG) log(m_status);
			return 0;
		}

		if (m_timer.fd == fd_t.init || m_timer.fd == timer_id)
		{
			m_timer.fd = timer_id;
			m_timer.cb = del;
		}
		else {
			try
			{
				(m_timerHandlers)[timer_id] = del;
			}
			catch (Exception e) {
				setInternalError!"HashMap assign"(Status.ERROR);
				return 0;
			}
		}


		return timer_id;
	}

	fd_t run(AsyncDirectoryWatcher ctxt, DWHandler del)
	{
		static fd_t ids;
		auto fd = ++ids;

		try (m_dwHandlers)[fd] = new DWHandlerInfo(del);
		catch (Exception e) {
			setInternalError!"AsyncDirectoryWatcher.hashMap(run)"(Status.ERROR, "Could not add handler to hashmap: " ~ e.msg);
		}

		return fd;

	}

	bool kill(AsyncDirectoryWatcher ctxt) {

		try {
			Array!DWFolderWatcher toFree;
			foreach (ref const uint k, const DWFolderWatcher v; m_dwFolders) {
				if (v.fd == ctxt.fd) {
					CloseHandle(v.handle);
					m_dwFolders.remove(k);
				}
			}

			foreach (DWFolderWatcher obj; toFree[])
				ThreadMem.free(obj);

			// todo: close all the handlers...
			m_dwHandlers.remove(ctxt.fd);
		}
		catch (Exception e) {
			setInternalError!"in kill(AsyncDirectoryWatcher)"(Status.ERROR, e.msg);
			return false;
		}

		return true;
	}

	bool kill(AsyncTCPConnection ctxt, bool forced = false)
	{

		m_status = StatusInfo.init;
		fd_t fd = ctxt.socket;

		static if (LOG) log("Killing socket "~ fd.to!string);
		try {
			auto cb = m_tcpHandlers.get(ctxt.socket);
			if (cb != TCPEventHandler.init){
				*cb.conn.connected = false;
				*cb.conn.connecting = false;
				return closeSocket(fd, true, forced);
			}
		} catch (Exception e) {
			setInternalError!"in m_tcpHandlers"(Status.ERROR, e.msg);
			assert(false);
			//return false;
		}

		return true;
	}

	bool kill(AsyncTCPListener ctxt)
	{
		m_status = StatusInfo.init;
		fd_t fd = ctxt.socket;
		try {
			if ((ctxt.socket in m_connHandlers) !is null) {
				return closeSocket(fd, false, true);
			}
		} catch (Exception e) {
			setInternalError!"in m_connHandlers"(Status.ERROR, e.msg);
			return false;
		}

		return true;
	}

	bool kill(shared AsyncSignal ctxt) {
		return true;
	}

	bool kill(AsyncNotifier ctxt) {
		return true;
	}

	bool kill(AsyncTimer ctxt) {
		m_status = StatusInfo.init;

		static if (LOG) try log("Kill timer" ~ ctxt.id.to!string); catch (Throwable) {}

		BOOL err = KillTimer(m_hwnd, ctxt.id);
		if (err == 0)
		{
			m_error = GetLastErrorSafe();
			m_status.code = Status.ERROR;
			m_status.text = "kill(AsyncTimer)";
			static if (LOG) log(m_status);
			return false;
		}

		destroyIndex(ctxt);
		scope(exit)
			ctxt.id = fd_t.init;
		if (m_timer.fd == ctxt.id) {
			ctxt.id = 0;
			m_timer = TimerCache.init;
		} else {
			try {
				m_timerHandlers.remove(ctxt.id);
			}
			catch (Exception e) {
				setInternalError!"HashMap remove"(Status.ERROR);
				return 0;
			}
		}


		return true;
	}

	bool kill(AsyncEvent ctxt, bool forced = false) {
		return true;
	}

	bool kill(AsyncUDPSocket ctxt) {
		m_status = StatusInfo.init;

		fd_t fd = ctxt.socket;
		INT err = closesocket(fd);
		if (catchSocketError!"closesocket"(err))
			return false;

		try m_udpHandlers.remove(ctxt.socket);
		catch (Exception e) {
			setInternalError!"HashMap remove"(Status.ERROR);
			return 0;
		}

		return true;
	}

	bool setOption(T)(fd_t fd, TCPOption option, in T value) {
		m_status = StatusInfo.init;
		int err;
		try {
			nothrow bool errorHandler() {
				if (catchSocketError!"setOption:"(err)) {
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
						BOOL val = value?1:0;
						socklen_t len = val.sizeof;
						err = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &val, len);
						return errorHandler();
					}
				case TCPOption.REUSEPORT:
				case TCPOption.REUSEADDR: // true/false
					static if (!is(T == bool))
						assert(false, "REUSEADDR value type must be bool, not " ~ T.stringof);
					else
					{
						BOOL val = value?1:0;
						socklen_t len = val.sizeof;
						err = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &val, len);
						return errorHandler();
					}
				case TCPOption.QUICK_ACK:
					static if (!is(T == bool))
						assert(false, "QUICK_ACK value type must be bool, not " ~ T.stringof);
					else {
						m_status.code = Status.NOT_IMPLEMENTED;
						return false; // quick ack is not implemented
					}
				case TCPOption.KEEPALIVE_ENABLE: // true/false
					static if (!is(T == bool))
						assert(false, "KEEPALIVE_ENABLE value type must be bool, not " ~ T.stringof);
					else
					{
						BOOL val = value?1:0;
						socklen_t len = val.sizeof;
						err = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &val, len);
						return errorHandler();
					}
				case TCPOption.KEEPALIVE_COUNT: // retransmit 10 times before dropping half-open conn
					static if (!isIntegral!T)
						assert(false, "KEEPALIVE_COUNT value type must be integral, not " ~ T.stringof);
					else {
						m_status.code = Status.NOT_IMPLEMENTED;
						return false;
					}
				case TCPOption.KEEPALIVE_INTERVAL: // wait ## seconds between each keepalive packets
					static if (!is(T == Duration))
						assert(false, "KEEPALIVE_INTERVAL value type must be Duration, not " ~ T.stringof);
					else {

						if (!kcache)
							kcache = new HashMap!(fd_t, tcp_keepalive)();

						tcp_keepalive kaSettings = kcache.get(fd, tcp_keepalive.init);
						tcp_keepalive sReturned;
						DWORD dwBytes;
						kaSettings.onoff = ULONG(1);
						if (kaSettings.keepalivetime == ULONG.init) {
							kaSettings.keepalivetime = 1000;
						}
						kaSettings.keepaliveinterval = value.total!"msecs".to!ULONG;
						(*kcache)[fd] = kaSettings;
						err = WSAIoctl(fd, SIO_KEEPALIVE_VALS, &kaSettings, tcp_keepalive.sizeof, &sReturned, tcp_keepalive.sizeof, &dwBytes, null, null);

						return errorHandler();
					}
				case TCPOption.KEEPALIVE_DEFER: // wait ## seconds until start
					static if (!is(T == Duration))
						assert(false, "KEEPALIVE_DEFER value type must be Duration, not " ~ T.stringof);
					else {

						if (!kcache)
							kcache = new HashMap!(fd_t, tcp_keepalive)();

						tcp_keepalive kaSettings = kcache.get(fd, tcp_keepalive.init);
						tcp_keepalive sReturned;
						DWORD dwBytes;
						kaSettings.onoff = ULONG(1);
						if (kaSettings.keepaliveinterval == ULONG.init) {
							kaSettings.keepaliveinterval = 75*1000;
						}
						kaSettings.keepalivetime = value.total!"msecs".to!ULONG;

						(*kcache)[fd] = kaSettings;
						err = WSAIoctl(fd, SIO_KEEPALIVE_VALS, &kaSettings, tcp_keepalive.sizeof, &sReturned, tcp_keepalive.sizeof, &dwBytes, null, null);

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
						DWORD val = value.total!"msecs".to!DWORD;
						socklen_t len = val.sizeof;
						err = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &val, len);
						return errorHandler();
					}
				case TCPOption.TIMEOUT_SEND:
					static if (!is(T == Duration))
						assert(false, "TIMEOUT_SEND value type must be Duration, not " ~ T.stringof);
					else {
						DWORD val = value.total!"msecs".to!DWORD;
						socklen_t len = val.sizeof;
						err = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &val, len);
						return errorHandler();
					}
				case TCPOption.TIMEOUT_HALFOPEN:
					static if (!is(T == Duration))
						assert(false, "TIMEOUT_SEND value type must be Duration, not " ~ T.stringof);
					else {
						m_status.code = Status.NOT_IMPLEMENTED;
						return false;
					}
				case TCPOption.LINGER: // bool onOff, int seconds
					static if (!is(T == Tuple!(bool, int)))
						assert(false, "LINGER value type must be Tuple!(bool, int), not " ~ T.stringof);
					else {
						linger l = linger(val[0]?1:0, val[1].to!USHORT);
						socklen_t llen = l.sizeof;
						err = setsockopt(fd, SOL_SOCKET, SO_LINGER, &l, llen);
						return errorHandler();
					}
				case TCPOption.CONGESTION:
					static if (!isIntegral!T)
						assert(false, "CONGESTION value type must be integral, not " ~ T.stringof);
					else {
						m_status.code = Status.NOT_IMPLEMENTED;
						return false;
					}
				case TCPOption.CORK:
					static if (!isIntegral!T)
						assert(false, "CORK value type must be int, not " ~ T.stringof);
					else {
						m_status.code = Status.NOT_IMPLEMENTED;
						return false;
					}
				case TCPOption.DEFER_ACCEPT: // seconds
					static if (!isIntegral!T)
						assert(false, "DEFER_ACCEPT value type must be integral, not " ~ T.stringof);
					else {
						int val = value.to!int;
						socklen_t len = val.sizeof;
						err = setsockopt(fd, SOL_SOCKET, SO_CONDITIONAL_ACCEPT, &val, len);
						return errorHandler();
					}
			}

		}
		catch (Exception e) {
			return false;
		}

	}

	uint read(in fd_t fd, ref ubyte[] data)
	{
		return 0;
	}

	uint write(in fd_t fd, in ubyte[] data)
	{
		return 0;
	}

	uint readChanges(in fd_t fd, ref DWChangeInfo[] dst) {
		size_t i;
		Array!DWChangeInfo* changes;
		try {
			changes = &(m_dwHandlers.get(fd, DWHandlerInfo.init).buffer);
			if ((*changes).empty)
				return 0;

			import std.algorithm : min;
			size_t cnt = min(dst.length, changes.length);
			foreach (DWChangeInfo change; (*changes)[0 .. cnt]) {
				static if (LOG) try log("reading change: " ~ change.path); catch (Throwable) {}
				dst[i] = (*changes)[i];
				i++;
			}
			changes.linearRemove((*changes)[0 .. cnt]);
		}
		catch (Exception e) {
			setInternalError!"watcher.readChanges"(Status.ERROR, "Could not read directory changes: " ~ e.msg);
			return 0;
		}
		static if (LOG) try log("Changes returning with: " ~ i.to!string); catch (Throwable) {}
		return cast(uint) i;
	}

	uint watch(in fd_t fd, in WatchInfo info) {
		m_status = StatusInfo.init;
		uint wd;
		try {
			HANDLE hndl = CreateFileW(toUTFz!(const(wchar)*)(info.path.toNativeString()),
			                          FILE_LIST_DIRECTORY,
			                          FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
			                          null,
			                          OPEN_EXISTING,
			                          FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
			                          null);
			wd = cast(uint) hndl;
			DWHandlerInfo handler = m_dwHandlers.get(fd, DWHandlerInfo.init);
			assert(handler !is null);
			static if (LOG) log("Watching: " ~ info.path.toNativeString());
			(m_dwFolders)[wd] = ThreadMem.alloc!DWFolderWatcher(m_evLoop, fd, hndl, info.path, info.events, handler, info.recursive);
		} catch (Exception e) {
			setInternalError!"watch"(Status.ERROR, "Could not start watching directory: " ~ e.msg);
			return 0;
		}
		return wd;
	}

	bool unwatch(in fd_t fd, in fd_t _wd) {
		uint wd = cast(uint) _wd;
		m_status = StatusInfo.init;
		try {
			DWFolderWatcher fw = m_dwFolders.get(wd, null);
			assert(fw !is null);
			m_dwFolders.remove(wd);
			fw.close();
			ThreadMem.free(fw);
		} catch (Exception e) {
			setInternalError!"unwatch"(Status.ERROR, "Failed when unwatching directory: " ~ e.msg);
			return false;
		}
		return true;
	}

	bool notify(T)(in fd_t fd, in T payload)
		if (is(T == shared AsyncSignal) || is(T == AsyncNotifier))
	{
		m_status = StatusInfo.init;
		import std.conv;

		auto payloadPtr = cast(ubyte*)payload;
		auto payloadAddr = cast(ulong)payloadPtr;

		WPARAM wparam = payloadAddr & 0xffffffff;
		LPARAM lparam = cast(uint) (payloadAddr >> 32);

		BOOL err;
		static if (is(T == AsyncNotifier))
			err = PostMessageA(cast(HWND)fd, WM_USER_SIGNAL, wparam, lparam);
		else
			err = PostMessageA(cast(HWND)fd, WM_USER_EVENT, wparam, lparam);
		static if (LOG) try log("Sending notification to: " ~ (cast(HWND)fd).to!string); catch (Throwable) {}
		if (err == 0)
		{
			m_error = GetLastErrorSafe();
			m_status.code = Status.ERROR;
			m_status.text = "notify";
			static if (LOG) log(m_status);
			return false;
		}
		return true;
	}

	fd_t run(AsyncSocket ctxt)
	{
		m_status = StatusInfo.init;

		auto fd = ctxt.preInitializedHandle;

		if (fd == INVALID_SOCKET) {
			fd = WSASocketW(ctxt.info.domain, ctxt.info.type, ctxt.info.protocol, null, 0, WSA_FLAG_OVERLAPPED);
		}

		if (catchErrors!"socket"(fd)) {
			.error("Failed to create socket: ", error);
			return INVALID_SOCKET;
		}

		return fd;
	}

	bool kill(AsyncSocket ctxt, bool forced = false)
	{
		m_status = StatusInfo.init;

		auto handle = ctxt.resetHandle();

		if (ctxt.connectionOriented && ctxt.passive) {
			foreach (request; m_completedSocketAccepts) if (request.socket is ctxt) {
				sockaddr* localAddress, remoteAddress;
				socklen_t localAddressLength, remoteAddressLength;

				GetAcceptExSockaddrs(request.buffer.ptr,
									 0,
									 cast(DWORD) request.buffer.length / 2,
									 cast(DWORD) request.buffer.length / 2,
									 &localAddress,
									 &localAddressLength,
									 &remoteAddress,
									 &remoteAddressLength);

				m_completedSocketAccepts.removeFront();
				if (!onAccept(handle, request, remoteAddress)) {
					.warning("Failed to accept incoming connection request while killing listener");
				}
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

			if(!CancelIo(cast(HANDLE) handle)) {
				m_status.code = Status.ABORT;
				m_error = GetLastErrorSafe();
				.error("Failed to cancel outstanding overlapped I/O requests: ", this.error);
				return false;
			}
		}

		if (ctxt.connectionOriented && ctxt.passive) {
			foreach (overlapped; cast(AsyncOverlapped*[]) m_pendingAccepts.keys) {
				if (overlapped.accept.socket is ctxt) {
					m_pendingAccepts.remove(overlapped);
					assumeWontThrow(AsyncOverlapped.free(overlapped));
				}
			}
		} else if (ctxt.connectionOriented && !ctxt.passive && ctxt in m_pendingConnects) {
			auto overlapped = cast(AsyncOverlapped*) m_pendingConnects[ctxt];
			m_pendingConnects.remove(ctxt);
			assumeWontThrow(AsyncOverlapped.free(overlapped));
		}

		if (ctxt.connectionOriented && !ctxt.passive) {
			*ctxt.connected = false;
		}

		INT err;
		if (ctxt.connectionOriented) {
			if (forced) {
				err = shutdown(handle, SD_BOTH);
				closesocket(ctxt.handle);
			} else {
				err = shutdown(handle, SD_SEND);
			}
			if (catchSocketError!"shutdown"(err)) {
				return false;
			}
		} else {
			closesocket(handle);
		}

		return true;
	}

	bool bind(AsyncSocket ctxt, sockaddr* addr, socklen_t addrlen)
	{
		import libasync.internals.socket_compat : bind;

		auto err = bind(ctxt.handle, addr, addrlen);
		if (catchSocketError!"bind"(err)) {
			.error("Failed to bind socket: ", error);
			return false;
		}

		return true;
	}

	bool connect(AsyncSocket ctxt, sockaddr* addr, socklen_t addrlen)
	{
		m_status = StatusInfo.init;

		// Connectionless sockets can be connected immediately,
		// as this only sets the default remote address.
		if (!ctxt.connectionOriented) {
			import libasync.internals.socket_compat : connect;

			auto err = connect(ctxt.handle, addr, addrlen);
			if (catchSocketError!"connect"(err)) {
				.error("Failed to connect socket: ", error);
				return false;
			}
			return true;
		}

		// ConnectEx requires a bound connection-oriented socket.
		try ctxt.localAddress; catch (SocketOSException) {
			NetworkAddress local;
			switch (ctxt.info.domain) {
				case AF_INET:
					local.addr_ip4.sin_family = AF_INET;
					local.addr_ip4.sin_addr.s_addr = INADDR_ANY;
					local.addr_ip4.sin_port = 0;
					break;
				case AF_INET6:
					local.addr_ip6.sin6_family = AF_INET6;
					local.addr_ip6.sin6_addr = IN6ADDR_ANY;
					local.addr_ip6.sin6_port = 0;
					break;
				default:
					assert(false, "Unsupported address family");
			}

			if (!bind(ctxt, local.sockAddr, local.sockAddrLen)) {
				return false;
			}
		} catch (Exception e) assert(false);

		auto overlapped = assumeWontThrow(AsyncOverlapped.alloc());
		overlapped.hEvent = pendingConnectEvent;
		if (ConnectEx(ctxt.handle, addr, addrlen, null, 0, null, &overlapped.overlapped)) {
			assumeWontThrow(AsyncOverlapped.free(overlapped));
			if (updateConnectContext(ctxt.handle)) {
				ctxt.handleConnect();
				return true;
			} else {
				ctxt.kill();
				ctxt.handleError();
				return false;
			}
		} else {
			m_error = WSAGetLastErrorSafe();
			if (m_error == WSA_IO_PENDING) {
				m_pendingConnects[ctxt] = overlapped;
				return true;
			} else {
				m_status.code = Status.ABORT;
				ctxt.kill();
				ctxt.handleError();
				return false;
			}
		}
	}

	auto updateAcceptContext(fd_t listener, fd_t socket)
	{
		auto err = setsockopt(socket, SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT, &listener, listener.sizeof);
		if (catchSocketError!"accept"(err)) {
			.error("Failed to setup accepted socket: ", error);
			return false;
		}
		else return true;
	}

	auto updateConnectContext(fd_t socket)
	{
		auto err = setsockopt(socket, SOL_SOCKET, SO_UPDATE_CONNECT_CONTEXT, null, 0);
		if (catchSocketError!"connect"(err)) {
			.error("Failed to setup connected socket: ", error);
			return false;
		}
		else return true;
	}

	/+
	bool setupConnectedCOASocket(AsyncSocket ctxt, AsyncSocket incomingOn = null)
	{
		fd_t err;

		*ctxt.connected = true;

		if (incomingOn) {
			auto listenerHandle = incomingOn.handle;
			err = setsockopt(ctxt.handle, SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT, &listenerHandle, listenerHandle.sizeof);
			if (catchSocketError!"connect"(err)) {
				.error("Failed to setup connected socket: ", error);
				ctxt.handleError();
				return false;
			}
		} else {
			err = setsockopt(ctxt.handle, SOL_SOCKET, SO_UPDATE_CONNECT_CONTEXT, null, 0);
			if (catchSocketError!"connect"(err)) {
				.error("Failed to setup connected socket: ", error);
				ctxt.handleError();
				return false;
			}
		}

		return true;
	}
	+/

	bool listen(AsyncSocket ctxt, int backlog)
	{
		import libasync.internals.socket_compat : listen;

		auto err = listen(ctxt.handle, backlog);
		if (catchSocketError!"listen"(err)) {
			.error("Failed to listen on socket: ", error);
			return false;
		}
		return true;
	}

	bool onAccept(fd_t listener, AsyncAcceptRequest* request, sockaddr* remoteAddress)
	{
		auto socket = request.socket;
		scope (exit) assumeWontThrow(AsyncAcceptRequest.free(request));

		if (!updateAcceptContext(listener, request.peer)) {
			if (socket.alive) {
				m_status.code = Status.ABORT;
				socket.kill();
				socket.handleError();
			}
			return false;
		}

		auto peer = request.onComplete(request.peer, remoteAddress.sa_family, socket.info.type, socket.info.protocol);
		if (peer.run()) {
			peer.handleConnect();
			return true;
		} else {
			peer.kill();
			peer.handleError();
			return false;
		}
	}

	void submitRequest(AsyncAcceptRequest* request)
	{
		auto overlapped = assumeWontThrow(AsyncOverlapped.alloc());
		overlapped.accept = request;
		overlapped.hEvent = pendingAcceptEvent;

		auto socket = request.socket;

		request.peer = WSASocketW(request.socket.info.domain,
								  request.socket.info.type,
								  request.socket.info.protocol,
								  null, 0, WSA_FLAG_OVERLAPPED);

		if (request.peer == SOCKET_ERROR) {
			m_error = WSAGetLastErrorSafe();

			assumeWontThrow(AsyncOverlapped.free(overlapped));
			assumeWontThrow(AsyncAcceptRequest.free(request));

			.errorf("Failed to create peer socket with WSASocket: %s", error);
			m_status.code = Status.ABORT;
			socket.kill();
			socket.handleError();
			return;
		}

		DWORD bytesReceived;
	retry:
		if (AcceptEx(socket.handle,
		             request.peer,
		             request.buffer.ptr,
		             0,
		             cast(DWORD) request.buffer.length / 2,
		             cast(DWORD) request.buffer.length / 2,
		             &bytesReceived,
		             &overlapped.overlapped)) {
			assumeWontThrow(AsyncOverlapped.free(overlapped));
			m_completedSocketAccepts.insertBack(request);
			return;
		} else {
			m_error = WSAGetLastErrorSafe();
			if (m_error == WSA_IO_PENDING) {
				m_pendingAccepts[overlapped] = true;
				return;
			// AcceptEx documentation states this error happens if "an incoming connection was indicated,
			// but was subsequently terminated by the remote peer prior to accepting the call".
			// This means there is no pending accept and we have to call AcceptEx again; this,
			// however, is a potential avenue for a denial-of-service attack, in which clients start
			// a connection to us but immediately terminate it, resulting in a (theoretically) infinite
			// loop here. The alternative to continuous resubmitting is closing the socket
			// (either immediately, or after a finite amount of tries to resubmit); that however, also opens up
			// a denial-of-service attack vector (a finite amount of such malicous connection attempts
			// can bring down any of our listening sockets). Of the two, the latter is a lot easier to exploit,
			// so for now we go with the first option of continuous resubmission.
			// TODO: Try to think of an better way to handle this.
			} else if (m_error == WSAECONNRESET) {
				goto retry;
			} else {
				m_status.code = Status.ABORT;
				assumeWontThrow(AsyncOverlapped.free(overlapped));
				assumeWontThrow(AsyncAcceptRequest.free(request));
				socket.kill();
				socket.handleError();
			}
		}
	}

	void submitRequest(AsyncReceiveRequest* request)
	{
		auto overlapped = assumeWontThrow(AsyncOverlapped.alloc());
		overlapped.receive = request;
		auto socket = request.socket;

		int err = void;
		if (!request.message) {
			.tracef("WSARecv on FD %s with zero byte buffer", socket.handle);
			WSABUF buffer;
			DWORD flags;
			err = WSARecv(socket.handle,
			              &buffer,
			              1,
			              null,
			              &flags,
			              cast(const(WSAOVERLAPPEDX*)) overlapped,
			              cast(LPWSAOVERLAPPED_COMPLETION_ROUTINEX) &onOverlappedReceiveComplete);
		} else if (request.message.name) {
			.tracef("WSARecvFrom on FD %s with buffer size %s",
			        socket.handle, request.message.header.msg_iov.len);
			err = WSARecvFrom(socket.handle,
			                  request.message.buffers,
			                  cast(DWORD) request.message.bufferCount,
			                  null,
			                  &request.message.header.msg_flags,
			                  request.message.name,
			                  &request.message.header.msg_namelen,
			                  cast(const(WSAOVERLAPPEDX*)) overlapped,
			                  cast(LPWSAOVERLAPPED_COMPLETION_ROUTINEX) &onOverlappedReceiveComplete);
		} else {
			.tracef("WSARecv on FD %s with buffer size %s",
			        socket.handle, request.message.header.msg_iov.len);
			err = WSARecv(socket.handle,
			              request.message.buffers,
			              cast(DWORD) request.message.bufferCount,
			              null,
			              &request.message.header.msg_flags,
			              cast(const(WSAOVERLAPPEDX*)) overlapped,
			              cast(LPWSAOVERLAPPED_COMPLETION_ROUTINEX) &onOverlappedReceiveComplete);
		}
		if (err == SOCKET_ERROR) {
			m_error = WSAGetLastErrorSafe();
			if (m_error == WSA_IO_PENDING) return;

			assumeWontThrow(AsyncOverlapped.free(overlapped));
			if (request.message) assumeWontThrow(NetworkMessage.free(request.message));
			assumeWontThrow(AsyncReceiveRequest.free(request));

			// TODO: Possibly deal with WSAEWOULDBLOCK, which supposedly signals
			//       too many pending overlapped I/O requests.
			if (m_error == WSAECONNRESET ||
			    m_error == WSAECONNABORTED ||
			    m_error == WSAENOTSOCK) {
				socket.handleClose();

				*socket.connected = false;

				closesocket(socket.handle);
				return;
			}

			.errorf("WSARecv* on FD %d encountered socket error: %s", socket.handle, this.error);
			m_status.code = Status.ABORT;
			socket.kill();
			socket.handleError();
		}
	}

	void submitRequest(AsyncSendRequest* request)
	{
		auto overlapped = assumeWontThrow(AsyncOverlapped.alloc());
		overlapped.send = request;
		auto socket = request.socket;

		int err = void;
		if (request.message.name) {
			.tracef("WSASendTo on FD %s for %s with buffer size %s",
			        socket.handle,
			        NetworkAddress(request.message.name, request.message.header.msg_namelen),
			        request.message.header.msg_iov.len);
			err = WSASendTo(socket.handle,
		                    request.message.buffers,
		                    cast(DWORD) request.message.bufferCount,
		                    null,
		                    request.message.header.msg_flags,
		                    request.message.name,
		                    request.message.nameLength,
		                    cast(const(WSAOVERLAPPEDX*)) overlapped,
		                    cast(LPWSAOVERLAPPED_COMPLETION_ROUTINEX) &onOverlappedSendComplete);
		} else {
			.tracef("WSASend on FD %s with buffer size %s", socket.handle, request.message.header.msg_iov.len);
			err = WSASend(socket.handle,
		                    request.message.buffers,
		                    cast(DWORD) request.message.bufferCount,
		                    null,
		                    request.message.header.msg_flags,
		                    cast(const(WSAOVERLAPPEDX*)) overlapped,
		                    cast(LPWSAOVERLAPPED_COMPLETION_ROUTINEX) &onOverlappedSendComplete);
		}

		if (err == SOCKET_ERROR) {
			m_error = WSAGetLastErrorSafe();
			if (m_error == WSA_IO_PENDING) return;

			assumeWontThrow(AsyncOverlapped.free(overlapped));
			assumeWontThrow(NetworkMessage.free(request.message));
			assumeWontThrow(AsyncSendRequest.free(request));

			// TODO: Possibly deal with WSAEWOULDBLOCK, which supposedly signals
			//       too many pending overlapped I/O requests.
			if (m_error == WSAECONNRESET ||
			    m_error == WSAECONNABORTED ||
			    m_error == WSAENOTSOCK) {
				socket.handleClose();

				*socket.connected = false;

				closesocket(socket.handle);
				return;
			}

			.errorf("WSASend* on FD %d encountered socket error: %s", socket.handle, this.error);
			m_status.code = Status.ABORT;
			socket.kill();
			socket.handleError();
		}
	}

	pragma(inline, true)
	uint recv(in fd_t fd, void[] data)
	{
		m_status = StatusInfo.init;
		int ret = .recv(fd, cast(void*) data.ptr, cast(INT) data.length, 0);

		//static if (LOG) try log("RECV " ~ ret.to!string ~ "B FD#" ~ fd.to!string); catch (Throwable) {}
		if (catchSocketError!".recv"(ret)) { // ret == -1
			if (m_error == error_t.WSAEWOULDBLOCK)
				m_status.code = Status.ASYNC;
			return 0; // TODO: handle some errors more specifically
		}

		return cast(uint) ret;
	}

	pragma(inline, true)
	uint send(in fd_t fd, in void[] data)
	{
		m_status = StatusInfo.init;
		static if (LOG) try log("SEND " ~ data.length.to!string ~ "B FD#" ~ fd.to!string);
		catch (Throwable) {}
		int ret = .send(fd, cast(const(void)*) data.ptr, cast(INT) data.length, 0);

		if (catchSocketError!"send"(ret)) {
			if (m_error == error_t.WSAEWOULDBLOCK)
				m_status.code = Status.ASYNC;
			return 0; // TODO: handle some errors more specifically
		}
		return cast(uint) ret;
	}

	bool broadcast(in fd_t fd, bool b) {
	
		int val = b?1:0;
		socklen_t len = val.sizeof;
		int err = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &val, len);
		if (catchSocketError!"setsockopt"(err))
			return false;
	
		return true;

	}

	uint recvFrom(in fd_t fd, void[] data, ref NetworkAddress addr)
	{
		m_status = StatusInfo.init;

		addr.family = AF_INET6;
		socklen_t addrLen = addr.sockAddrLen;
		int ret = .recvfrom(fd, cast(void*) data.ptr, cast(INT) data.length, 0, addr.sockAddr, &addrLen);

		if (addrLen < addr.sockAddrLen) {
			addr.family = AF_INET;
		}

		static if (LOG) try log("RECVFROM " ~ ret.to!string ~ "B"); catch (Throwable) {}
		if (catchSocketError!".recvfrom"(ret)) { // ret == -1
			if (m_error == WSAEWOULDBLOCK)
				m_status.code = Status.ASYNC;
			return 0; // TODO: handle some errors more specifically
		}
		m_status.code = Status.OK;

		return cast(uint) ret;
	}

	uint sendTo(in fd_t fd, in void[] data, in NetworkAddress addr)
	{
		m_status = StatusInfo.init;
		static if (LOG) try log("SENDTO " ~ data.length.to!string ~ "B " ~ addr.toString()); catch (Throwable) {}
		int ret;
		if (addr != NetworkAddress.init)
			ret = .sendto(fd, cast(void*) data.ptr, cast(INT) data.length, 0, addr.sockAddr, addr.sockAddrLen);
		else
			ret = .send(fd, cast(void*) data.ptr, cast(INT) data.length, 0);

		if (catchSocketError!".sendTo"(ret)) { // ret == -1
			if (m_error == WSAEWOULDBLOCK)
				m_status.code = Status.ASYNC;
			return 0; // TODO: handle some errors more specifically
		}

		m_status.code = Status.OK;
		return cast(uint) ret;
	}

	NetworkAddress localAddr(in fd_t fd, bool ipv6) {
		NetworkAddress ret;
		import libasync.internals.win32 : getsockname, AF_INET, AF_INET6, socklen_t, sockaddr;
		if (ipv6)
			ret.family = AF_INET6;
		else
			ret.family = AF_INET;
		socklen_t len = ret.sockAddrLen;
		int err = getsockname(fd, ret.sockAddr, &len);
		if (catchSocketError!"getsockname"(err))
			return NetworkAddress.init;
		if (len > ret.sockAddrLen)
			ret.family = AF_INET6;
		return ret;
	}

	void noDelay(in fd_t fd, bool b) {
		m_status = StatusInfo.init;
		setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &b, b.sizeof);
	}

	private bool closeRemoteSocket(fd_t fd, bool forced) {

		INT err;

		static if (LOG) try log("Shutdown FD#" ~ fd.to!string);
		catch (Throwable) {}
		if (forced) {
			err = shutdown(fd, SD_BOTH);
			closesocket(fd);
		}
		else
			err = shutdown(fd, SD_SEND);

		try {
			TCPEventHandler* evh = fd in m_tcpHandlers;
			if (evh) {
				if (evh.conn.inbound) {
					try ThreadMem.free(evh.conn);
					catch(Exception e) { assert(false, "Failed to free resources"); }
				}

				evh.conn = null;
				//static if (LOG) log("Remove event handler for " ~ fd.to!string);
				m_tcpHandlers.remove(fd);
			}
		}
		catch (Exception e) {
			setInternalError!"m_tcpHandlers.remove"(Status.ERROR);
			return false;
		}
		if (catchSocketError!"shutdown"(err))
			return false;
		return true;
	}

	// for connected sockets
	bool closeSocket(fd_t fd, bool connected, bool forced = false)
	{
		m_status = StatusInfo.init;
		if (!connected && forced) {
			try {
				if (fd in m_connHandlers) {
					static if (LOG) log("Removing connection handler for: " ~ fd.to!string);
					m_connHandlers.remove(fd);
				}
			}
			catch (Exception e) {
				setInternalError!"m_connHandlers.remove"(Status.ERROR);
				return false;
			}
		}
		else if (connected)
			closeRemoteSocket(fd, forced);

		if (!connected || forced) {
			// todo: flush the socket here?

			INT err = closesocket(fd);
			if (catchSocketError!"closesocket"(err))
				return false;

		}
		return true;
	}

	bool closeConnection(fd_t fd) {
		return closeSocket(fd, true);
	}

	NetworkAddress getAddressFromIP(in string ipAddr, in ushort port = 0, in bool ipv6 = false, in bool tcp = true)
	{
		m_status = StatusInfo.init;

		NetworkAddress addr;
		WSAPROTOCOL_INFOW hints;
		import std.conv : to;
		if (ipv6) {
			addr.family = AF_INET6;
		}
		else {
			addr.family = AF_INET;
		}

		INT addrlen = addr.sockAddrLen;

		LPWSTR str;
		try {
			str = cast(LPWSTR) toUTFz!(wchar*)(ipAddr);
		} catch (Exception e) {
			setInternalError!"toStringz"(Status.ERROR, e.msg);
			return NetworkAddress.init;
		}

		INT err = WSAStringToAddressW(str, cast(INT) addr.family, null, addr.sockAddr, &addrlen);
		if (port != 0) addr.port = port;
		static if (LOG) try log(addr.toString());
		catch (Throwable) {}
		if( catchSocketError!"getAddressFromIP"(err) )
			return NetworkAddress.init;
		else assert(addrlen == addr.sockAddrLen);
		return addr;
	}

	NetworkAddress getAddressFromDNS(in string host, in ushort port = 0, in bool ipv6 = true, in bool tcp = true, in bool force = true)
		/*in {
		debug import libasync.internals.validator : validateHost;
		debug assert(validateHost(host), "Trying to connect to an invalid domain");
	}
	body */{
		m_status = StatusInfo.init;
		import std.conv : to;
		NetworkAddress addr;
		ADDRINFOW hints;
		ADDRINFOW* infos;
		LPCWSTR wPort = port.to!(wchar[]).toUTFz!(const(wchar)*);
		if (ipv6) {
			hints.ai_family = AF_INET6;
			addr.family = AF_INET6;
		}
		else {
			hints.ai_family = AF_INET;
			addr.family = AF_INET;
		}

		if (tcp) {
			hints.ai_protocol = IPPROTO_TCP;
			hints.ai_socktype = SOCK_STREAM;
		}
		else {
			hints.ai_protocol = IPPROTO_UDP;
			hints.ai_socktype = SOCK_DGRAM;
		}
		if (port != 0) addr.port = port;

		LPCWSTR str;

		try {
			str = cast(LPCWSTR) toUTFz!(immutable(wchar)*)(host);
		} catch (Exception e) {
			setInternalError!"toUTFz"(Status.ERROR, e.msg);
			return NetworkAddress.init;
		}

		error_t err = cast(error_t) GetAddrInfoW(str, cast(LPCWSTR) wPort, &hints, &infos);
		scope(exit) FreeAddrInfoW(infos);
		if (err != EWIN.WSA_OK) {
			setInternalError!"GetAddrInfoW"(Status.ABORT, string.init, err);
			return NetworkAddress.init;
		}

		ubyte* pAddr = cast(ubyte*) infos.ai_addr;
		ubyte* data = cast(ubyte*) addr.sockAddr;
		data[0 .. infos.ai_addrlen] = pAddr[0 .. infos.ai_addrlen]; // perform bit copy
		static if (LOG) try log("GetAddrInfoW Successfully resolved DNS to: " ~ addr.toAddressString());
		catch (Exception e){}
		return addr;
	}

	pragma(inline, true)
	void setInternalError(string TRACE)(in Status s, in string details = "", in error_t error = EWIN.ERROR_ACCESS_DENIED)
	{
		if (details.length > 0)
			m_status.text = TRACE ~ ": " ~ details;
		else
			m_status.text = TRACE;
		m_error = error;
		m_status.code = s;
		static if(LOG) log(m_status);
	}
private:
	bool onMessage(MSG msg)
	{
		m_status = StatusInfo.init;
		switch (msg.message) {
			case WM_TCP_SOCKET:
				auto evt = LOWORD(msg.lParam);
				auto err = HIWORD(msg.lParam);
				if (!onTCPEvent(evt, err, cast(fd_t)msg.wParam)) {

					if (evt == FD_ACCEPT)
						setInternalError!"del@TCPAccept.ERROR"(Status.ERROR);
					else {
						try {
							TCPEventHandler cb = m_tcpHandlers.get(cast(fd_t)msg.wParam);
							cb(TCPEvent.ERROR);
						}
						catch (Exception e) {
							// An Error callback should never fail...
							setInternalError!"del@TCPEvent.ERROR"(Status.ERROR);
							// assert(false, evt.to!string ~ " & " ~ m_status.to!string ~ " & " ~ m_error.to!string);
						}
					}
				}
				break;
			case WM_UDP_SOCKET:
				auto evt = LOWORD(msg.lParam);
				auto err = HIWORD(msg.lParam);
				if (!onUDPEvent(evt, err, cast(fd_t)msg.wParam)) {
					try {
						UDPHandler cb = m_udpHandlers.get(cast(fd_t)msg.wParam);
						cb(UDPEvent.ERROR);
					}
					catch (Exception e) {
						// An Error callback should never fail...
						setInternalError!"del@UDPEvent.ERROR"(Status.ERROR);
					}
				}
				break;
			case WM_TIMER:
				static if (LOG) try log("Timer callback: " ~ m_timer.fd.to!string); catch (Throwable) {}
				TimerHandler cb;
				bool cached = (m_timer.fd == cast(fd_t)msg.wParam);
				try {
					if (cached)
						cb = m_timer.cb;
					else
						cb = m_timerHandlers.get(cast(fd_t)msg.wParam);
					cb.ctxt.rearmed = false;
					cb();

					if (cb.ctxt.oneShot && !cb.ctxt.rearmed)
						kill(cb.ctxt);

				}
				catch (Exception e) {
					// An Error callback should never fail...
					setInternalError!"del@TimerHandler"(Status.ERROR, e.msg);
				}

				break;
			case WM_USER_EVENT:
				static if (LOG) log("User event");

				ulong uwParam = cast(ulong)msg.wParam;
				ulong ulParam = cast(ulong)msg.lParam;

				ulong payloadAddr = (ulParam << 32) | uwParam;
				void* payloadPtr = cast(void*) payloadAddr;
				shared AsyncSignal ctxt = cast(shared AsyncSignal) payloadPtr;

				static if (LOG) try log("Got notification in : " ~ m_hwnd.to!string ~ " pointer: " ~ payloadPtr.to!string); catch (Throwable) {}
				try {
					assert(ctxt.id != 0);
					ctxt.handler();
				}
				catch (Exception e) {
					setInternalError!"WM_USER_EVENT@handler"(Status.ERROR);
				}
				break;
			case WM_USER_SIGNAL:
				static if (LOG) log("User signal");

				ulong uwParam = cast(ulong)msg.wParam;
				ulong ulParam = cast(ulong)msg.lParam;

				ulong payloadAddr = (ulParam << 32) | uwParam;
				void* payloadPtr = cast(void*) payloadAddr;
				AsyncNotifier ctxt = cast(AsyncNotifier) payloadPtr;

				try {
					ctxt.handler();
				}
				catch (Exception e) {
					setInternalError!"WM_USER_SIGNAL@handler"(Status.ERROR);
				}
				break;
			default: return false; // not handled, sends to wndProc
		}
		return true;
	}

	bool onUDPEvent(WORD evt, WORD err, fd_t sock) {
		m_status = StatusInfo.init;
		try{
			if (m_udpHandlers.get(sock) == UDPHandler.init)
				return false;
		}	catch (Throwable) {}
		if (sock == 0) { // highly unlikely...
			setInternalError!"onUDPEvent"(Status.ERROR, "no socket defined");
			return false;
		}
		if (err) {
			setInternalError!"onUDPEvent"(Status.ERROR, string.init, cast(error_t)err);
			try {
				//log("CLOSE FD#" ~ sock.to!string);
				(m_udpHandlers)[sock](UDPEvent.ERROR);
			} catch (Throwable) { // can't do anything about this...
			}
			return false;
		}

		UDPHandler cb;
		switch(evt) {
			default: break;
			case FD_READ:
				try {
					static if (LOG) log("READ FD#" ~ sock.to!string);
					cb = m_udpHandlers.get(sock);
					assert(cb != UDPHandler.init, "Socket " ~ sock.to!string ~ " could not yield a callback");
					cb(UDPEvent.READ);
				}
				catch (Exception e) {
					setInternalError!"del@TCPEvent.READ"(Status.ABORT);
					return false;
				}
				break;
			case FD_WRITE:
				try {
					static if (LOG) log("WRITE FD#" ~ sock.to!string);
					cb = m_udpHandlers.get(sock);
					assert(cb != UDPHandler.init, "Socket " ~ sock.to!string ~ " could not yield a callback");
					cb(UDPEvent.WRITE);
				}
				catch (Exception e) {
					setInternalError!"del@TCPEvent.WRITE"(Status.ABORT);
					return false;
				}
				break;
		}
		return true;
	}

	bool onTCPEvent(WORD evt, WORD err, fd_t sock) {
		m_status = StatusInfo.init;
		try{
			if (m_tcpHandlers.get(sock) == TCPEventHandler.init && m_connHandlers.get(sock) == TCPAcceptHandler.init)
				return false;
		} catch (Throwable) {}
		if (sock == 0) { // highly unlikely...
			setInternalError!"onTCPEvent"(Status.ERROR, "no socket defined");
			return false;
		}
		if (err) {
			setInternalError!"onTCPEvent"(Status.ERROR, string.init, cast(error_t)err);
			try {
				//log("CLOSE FD#" ~ sock.to!string);
				(m_tcpHandlers)[sock](TCPEvent.ERROR);
			} catch (Throwable) { // can't do anything about this...
			}
			return false;
		}

		TCPEventHandler cb;
		switch(evt) {
			default: break;
			case FD_ACCEPT:
				version(Distributed) gs_mtx.lock_nothrow();

				static if (LOG) log("TCP Handlers: " ~ m_tcpHandlers.length.to!string);
				static if (LOG) log("Accepting connection");
				/// Let another listener take the next connection
				TCPAcceptHandler list;
				try list = m_connHandlers[sock]; catch (Throwable) { assert(false, "Listening on an invalid socket..."); }
				scope(exit) {
					/// The connection rotation mechanism is handled by the TCPListenerDistMixins
					/// when registering the same AsyncTCPListener object on multiple event loops.
					/// This allows to even out the CPU usage on a server instance.
					version(Distributed)
					{
						HWND hwnd = list.ctxt.next(m_hwnd);
						if (hwnd !is HWND.init) {
							int error = WSAAsyncSelect(sock, hwnd, WM_TCP_SOCKET, FD_ACCEPT);
							if (catchSocketError!"WSAAsyncSelect.NEXT()=> HWND"(error)) {
								error = WSAAsyncSelect(sock, m_hwnd, WM_TCP_SOCKET, FD_ACCEPT);
								if (catchSocketError!"WSAAsyncSelect"(error))
									assert(false, "Could not set listener back to window HANDLE " ~ m_hwnd.to!string);
							}
						}
						else static if (LOG) log("Returned init!!");
						gs_mtx.unlock_nothrow();
					}
				}

				NetworkAddress addr;
				addr.family = AF_INET;
				int addrlen = addr.sockAddrLen;
				fd_t csock = WSAAccept(sock, addr.sockAddr, &addrlen, null, 0);

				if (catchSocketError!"WSAAccept"(csock, INVALID_SOCKET)) {
					if (m_error == WSAEFAULT) { // not enough space for sockaddr
						addr.family = AF_INET6;
						addrlen = addr.sockAddrLen;
						csock = WSAAccept(sock, addr.sockAddr, &addrlen, null, 0);
						if (catchSocketError!"WSAAccept"(csock, INVALID_SOCKET))
							return false;
					}
					else return false;
				}

				int ok = WSAAsyncSelect(csock, m_hwnd, WM_TCP_SOCKET, FD_CONNECT|FD_READ|FD_WRITE|FD_CLOSE);
				if ( catchSocketError!"WSAAsyncSelect"(ok) )
					return false;

				static if (LOG) log("Connection accepted: " ~ csock.to!string);

				AsyncTCPConnection conn;
				try conn = ThreadMem.alloc!AsyncTCPConnection(m_evLoop);
				catch (Exception e) { assert(false, "Failed allocation"); }
				conn.peer = addr;
				conn.socket = csock;
				conn.inbound = true;

				try {
					// Do the callback to get a handler
					cb = list(conn);
				}
				catch(Exception e) {
					setInternalError!"onConnected"(Status.EVLOOP_FAILURE);
					return false;
				}

				try {
					m_tcpHandlers[csock] = cb; // keep the handler to setup the connection
					static if (LOG) log("ACCEPT&CONNECT FD#" ~ csock.to!string);
					*conn.connected = true;
					cb(TCPEvent.CONNECT);
				}
				catch (Exception e) {
					setInternalError!"m_tcpHandlers.opIndexAssign"(Status.ABORT);
					return false;
				}
				break;
			case FD_CONNECT:
				try {
					static if (LOG) log("CONNECT FD#" ~ sock.to!string);
					cb = m_tcpHandlers.get(sock);
					if (cb == TCPEventHandler.init) break;//, "Socket " ~ sock.to!string ~ " could not yield a callback");
					*cb.conn.connecting = true;
				}
				catch(Exception e) {
					setInternalError!"del@TCPEvent.CONNECT"(Status.ABORT);
					return false;
				}
				break;
			case FD_READ:
				try {
					static if (LOG) log("READ FD#" ~ sock.to!string);
					cb = m_tcpHandlers.get(sock);
					if (cb == TCPEventHandler.init) break; //, "Socket " ~ sock.to!string ~ " could not yield a callback");
					if (!cb.conn) break;
					if (*cb.conn.connected == false && *cb.conn.connecting) {
						static if (LOG) log("TCPEvent CONNECT FD#" ~ sock.to!string);

						*cb.conn.connecting = false;
						*cb.conn.connected = true;
						cb(TCPEvent.CONNECT);
					}
					else {
						static if (LOG) log("TCPEvent READ FD#" ~ sock.to!string);
						cb(TCPEvent.READ);
					}
				}
				catch (Exception e) {
					setInternalError!"del@TCPEvent.READ"(Status.ABORT);
					return false;
				}
				break;
			case FD_WRITE:
				// todo: don't send the first write for consistency with epoll?

				try {
					//import std.stdio;
					static if (LOG) log("WRITE FD#" ~ sock.to!string);
					cb = m_tcpHandlers.get(sock);
					if (cb == TCPEventHandler.init) break;//assert(cb != TCPEventHandler.init, "Socket " ~ sock.to!string ~ " could not yield a callback");
					if (!cb.conn) break;
					if (*cb.conn.connected == false && *cb.conn.connecting) {
						*cb.conn.connecting = false;
						*cb.conn.connected = true;
						cb(TCPEvent.CONNECT);
					}
					else {
						cb(TCPEvent.WRITE);
					}
				}
				catch (Exception e) {
					setInternalError!"del@TCPEvent.WRITE"(Status.ABORT);
					return false;
				}
				break;
			case FD_CLOSE:
				// called after shutdown()
				INT ret;
				bool connected = true;
				try {
					static if (LOG) log("CLOSE FD#" ~ sock.to!string);
					if (sock in m_tcpHandlers) {
						cb = m_tcpHandlers.get(sock);
						if (*cb.conn.connected || *cb.conn.connecting) {
							cb(TCPEvent.CLOSE);
							*cb.conn.connecting = false;
							*cb.conn.connected = false;
						} else
							connected = false;
					}
					else
						connected = false;
				}
				catch (Exception e) {
					if (m_status.code == Status.OK)
						setInternalError!"del@TCPEvent.CLOSE"(Status.ABORT);
					return false;
				}

				closeSocket(sock, connected, true); // as necessary: invokes m_tcpHandlers.remove(fd), shutdown, closesocket

				break;
		}
		return true;
	}

	bool initUDPSocket(fd_t fd, AsyncUDPSocket ctxt)
	{
		INT err;
		static if (LOG) log("Binding to UDP " ~ ctxt.local.toString());

		if (!setOption(fd, TCPOption.REUSEADDR, true)) {
			closesocket(fd);
			return false;
		}

		err = .bind(fd, ctxt.local.sockAddr, ctxt.local.sockAddrLen);
		if (catchSocketError!"bind"(err)) {
			closesocket(fd);
			return false;
		}
		err = WSAAsyncSelect(fd, m_hwnd, WM_UDP_SOCKET, FD_READ | FD_WRITE);
		if (catchSocketError!"WSAAsyncSelect"(err)) {
			closesocket(fd);
			return false;
		}

		return true;
	}

	bool initTCPListener(fd_t fd, AsyncTCPListener ctxt, bool reusing = false)
	in {
		assert(m_threadId == GetCurrentThreadId());
		assert(ctxt.local !is NetworkAddress.init);
	}
	body {
		INT err;
		if (!reusing) {
			err = .bind(fd, ctxt.local.sockAddr, ctxt.local.sockAddrLen);
			if (catchSocketError!"bind"(err)) {
				closesocket(fd);
				return false;
			}

			err = .listen(fd, 128);
			if (catchSocketError!"listen"(err)) {
				closesocket(fd);
				return false;
			}

			err = WSAAsyncSelect(fd, m_hwnd, WM_TCP_SOCKET, FD_ACCEPT);
			if (catchSocketError!"WSAAsyncSelect"(err)) {
				closesocket(fd);
				return false;
			}
		}

		return true;
	}

	bool initTCPConnection(fd_t fd, AsyncTCPConnection ctxt)
	in {
		assert(ctxt.peer !is NetworkAddress.init);
		assert(ctxt.peer.port != 0, "Connecting to an invalid port");
	}
	body {
		INT err;
		NetworkAddress bind_addr;
		bind_addr.family = ctxt.peer.family;

		if (ctxt.peer.family == AF_INET)
			bind_addr.sockAddrInet4.sin_addr.s_addr = 0;
		else if (ctxt.peer.family == AF_INET6)
			bind_addr.sockAddrInet6.sin6_addr.s6_addr[] = 0;
		else {
			status.code = Status.ERROR;
			status.text = "Invalid NetworkAddress.family " ~ ctxt.peer.family.to!string;
			return false;
		}

		err = .bind(fd, bind_addr.sockAddr, bind_addr.sockAddrLen);
		if ( catchSocketError!"bind"(err) )
			return false;
		err = WSAAsyncSelect(fd, m_hwnd, WM_TCP_SOCKET, FD_CONNECT|FD_READ|FD_WRITE|FD_CLOSE);
		if ( catchSocketError!"WSAAsyncSelect"(err) )
			return false;
		err = .connect(fd, ctxt.peer.sockAddr, ctxt.peer.sockAddrLen);

		auto errors = [	tuple(cast(size_t) SOCKET_ERROR, EWIN.WSAEWOULDBLOCK, Status.ASYNC) ];

		if (catchSocketErrorsEq!"connectEQ"(err, errors)) {
			*ctxt.connecting = true;
			return true;
		}
		else if (catchSocketError!"connect"(err))
			return false;

		return true;
	}

	bool catchErrors(string TRACE, T)(T val, Tuple!(T, Status)[] cmp ...)
		if (isIntegral!T)
	{
		foreach (validator ; cmp) {
			if (val == validator[0]) {
				m_status.text = TRACE;
				m_status.code = validator[1];
				if (m_status.code == Status.EVLOOP_TIMEOUT) {
					static if (LOG) log(m_status);
					break;
				}
				m_error = GetLastErrorSafe();
				static if(LOG) log(m_status);
				return true;
			}
		}
		return false;
	}

	pragma(inline, true)
	bool catchSocketErrors(string TRACE, T)(T val, Tuple!(T, Status)[] cmp ...)
		if (isIntegral!T)
	{
		foreach (validator ; cmp) {
			if (val == validator[0]) {
				m_status.text = TRACE;
				m_error = WSAGetLastErrorSafe();
				m_status.status = validator[1];
				static if(LOG) log(m_status);
				return true;
			}
		}
		return false;
	}

	bool catchSocketErrorsEq(string TRACE, T)(T val, Tuple!(T, error_t, Status)[] cmp ...)
		if (isIntegral!T)
	{
		error_t err;
		foreach (validator ; cmp) {
			if (val == validator[0]) {
				if (err is EWIN.init) err = WSAGetLastErrorSafe();
				if (err == validator[1]) {
					m_status.text = TRACE;
					m_error = WSAGetLastErrorSafe();
					m_status.code = validator[2];
					static if(LOG) log(m_status);
					return true;
				}
			}
		}
		return false;
	}

	pragma(inline, true)
	bool catchSocketError(string TRACE, T)(T val, T cmp = SOCKET_ERROR)
		if (isIntegral!T)
	{
		if (val == cmp) {
			m_status.text = TRACE;
			m_error = WSAGetLastErrorSafe();
			m_status.code = Status.ABORT;
			static if(LOG) log(m_status);
			return true;
		}
		return false;
	}

	pragma(inline, true)
	error_t WSAGetLastErrorSafe() {
		try {
			return cast(error_t) WSAGetLastError();
		} catch(Exception e) {
			return EWIN.ERROR_ACCESS_DENIED;
		}
	}

	pragma(inline, true)
	error_t GetLastErrorSafe() {
		try {
			return cast(error_t) GetLastError();
		} catch(Exception e) {
			return EWIN.ERROR_ACCESS_DENIED;
		}
	}

	void log(StatusInfo val)
	{
		static if (LOG) {
			import std.stdio;
			try {
				writeln("Backtrace: ", m_status.text);
				writeln(" | Status:  ", m_status.code);
				writeln(" | Error: " , m_error);
				if ((m_error in EWSAMessages) !is null)
					writeln(" | Message: ", EWSAMessages[m_error]);
			} catch(Exception e) {
				return;
			}
		}
	}

	void log(T)(lazy T val)
	{
		static if (LOG) {
			import std.stdio;
			try {
				writeln(val);
			} catch(Exception e) {
				return;
			}
		}
	}

}

mixin template COSocketMixins() {

	private CleanupData m_impl;

	struct CleanupData {
		bool connected;
		bool connecting;
	}

	@property bool* connecting() {
		return &m_impl.connecting;
	}

	@property bool* connected() {
		return &m_impl.connected;
	}

}
/*
mixin template TCPListenerDistMixins()
{
	import core.sys.windows.windows : HWND;
	import libasync.internals.hashmap : HashMap;
	import core.sync.mutex;
	private {
		bool m_dist;

		Tuple!(WinReference, bool*) m_handles;
		__gshared HashMap!(fd_t, Tuple!(WinReference, bool*)) gs_dist;
		__gshared Mutex gs_mutex;
	}

	/// The TCP Listener schedules distributed connection handlers based on
	/// the event loops that are using the same AsyncTCPListener object.
	/// This is done by using WSAAsyncSelect on a different window after each
	/// accept TCPEvent.
	class WinReference {
		private {
			struct Item {
				HWND handle;
				bool active;
			}

			Item[] m_items;
		}

		this(HWND hndl, bool b) {
			append(hndl, b);
		}

		void append(HWND hndl, bool b) {
			m_items ~= Item(hndl, b);
		}

		HWND next(HWND me) {
			Item[] items;
			synchronized(gs_mutex)
				items = m_items;
			if (items.length == 1)
				return me;
			foreach (i, item; items) {
				if (item.active == true) {
					m_items[i].active = false; // remove responsibility
					if (m_items.length <= i + 1) {
						m_items[0].active = true; // set responsibility
						auto ret = m_items[0].handle;
						return ret;
					}
					else {
						m_items[i + 1].active = true;
						auto ret = m_items[i + 1].handle;
						return ret;
					}
				}

			}
			assert(false);
		}

	}

	void init(HWND hndl, fd_t sock) {
		try {
			if (!gs_mutex) {
				gs_mutex = new Mutex;
			}
			synchronized(gs_mutex) {
				m_handles = gs_dist.get(sock);
				if (m_handles == typeof(m_handles).init) {
					gs_dist[sock] = Tuple!(WinReference, bool*)(new WinReference(hndl, true), &m_dist);
					m_handles = gs_dist.get(sock);
					assert(m_handles != typeof(m_handles).init);
				}
				else {
					m_handles[0].append(hndl, false);
					*m_handles[1] = true; // set first thread to dist
					m_dist = true; // set this thread to dist
				}
			}
		} catch (Exception e) {
			assert(false, e.toString());
		}

	}

	HWND next(HWND me) {
		try {
			if (!m_dist)
				return HWND.init;
			return m_handles[0].next(me);
		}
		catch (Exception e) {
			assert(false, e.toString());
		}
	}

}*/
private class DWHandlerInfo {
	DWHandler handler;
	Array!DWChangeInfo buffer;

	this(DWHandler cb) {
		handler = cb;
	}
}

private final class DWFolderWatcher {
	import libasync.internals.path;
private:
	EventLoop m_evLoop;
	fd_t m_fd;
	bool m_recursive;
	HANDLE m_handle;
	Path m_path;
	DWFileEvent m_events;
	DWHandlerInfo m_handler; // contains buffer
	shared AsyncSignal m_signal;
	ubyte[FILE_NOTIFY_INFORMATION.sizeof + MAX_PATH + 1] m_buffer;
	DWORD m_bytesTransferred;
public:
	this(EventLoop evl, in fd_t fd, in HANDLE hndl, in Path path, in DWFileEvent events, DWHandlerInfo handler, bool recursive) {
		m_fd = fd;
		m_recursive = recursive;
		m_handle = cast(HANDLE)hndl;
		m_evLoop = evl;
		m_path = path;
		m_handler = handler;

		m_signal = new shared AsyncSignal(m_evLoop);
		m_signal.run(&onChanged);
		triggerWatch();
	}
package:
	void close() {
		CloseHandle(m_handle);
		m_signal.kill();
	}

	void triggerChanged() {
		m_signal.trigger();
	}

	void onChanged() {
		ubyte[] result = m_buffer.ptr[0 .. m_bytesTransferred];
		do {
			assert(result.length >= FILE_NOTIFY_INFORMATION.sizeof);
			auto fni = cast(FILE_NOTIFY_INFORMATION*)result.ptr;
			DWFileEvent kind;
			switch( fni.Action ){
				default: kind = DWFileEvent.MODIFIED; break;
				case 0x1: kind = DWFileEvent.CREATED; break;
				case 0x2: kind = DWFileEvent.DELETED; break;
				case 0x3: kind = DWFileEvent.MODIFIED; break;
				case 0x4: kind = DWFileEvent.MOVED_FROM; break;
				case 0x5: kind = DWFileEvent.MOVED_TO; break;
			}
			string filename = to!string(fni.FileName.ptr[0 .. fni.FileNameLength/2]); // FileNameLength = #bytes, FileName=WCHAR[]
			m_handler.buffer.insert(DWChangeInfo(kind, m_path ~ Path(filename)));
			if( fni.NextEntryOffset == 0 ) break;
			result = result[fni.NextEntryOffset .. $];
		} while(result.length > 0);

		triggerWatch();

		m_handler.handler();
	}

	void triggerWatch() {

		static UINT notifications = FILE_NOTIFY_CHANGE_FILE_NAME|FILE_NOTIFY_CHANGE_DIR_NAME|
			FILE_NOTIFY_CHANGE_SIZE|FILE_NOTIFY_CHANGE_LAST_WRITE;

		OVERLAPPED* overlapped = ThreadMem.alloc!OVERLAPPED();
		overlapped.Internal = 0;
		overlapped.InternalHigh = 0;
		overlapped.Offset = 0;
		overlapped.OffsetHigh = 0;
		overlapped.Pointer = cast(void*)this;
		import std.stdio;
		DWORD bytesReturned;
		BOOL success = ReadDirectoryChangesW(m_handle, m_buffer.ptr, m_buffer.length, cast(BOOL) m_recursive, notifications, &bytesReturned, overlapped, &onIOCompleted);

		static if (DEBUG) {
			import std.stdio;
			if (!success)
				writeln("Failed to call ReadDirectoryChangesW: " ~ EWSAMessages[GetLastError().to!EWIN]);
		}
	}

	@property fd_t fd() const {
		return m_fd;
	}

	@property HANDLE handle() const {
		return cast(HANDLE) m_handle;
	}

	static nothrow extern(System)
	{
		void onIOCompleted(DWORD dwError, DWORD cbTransferred, OVERLAPPED* overlapped)
		{
			import std.stdio;
			DWFolderWatcher watcher = cast(DWFolderWatcher)(overlapped.Pointer);
			watcher.m_bytesTransferred = cbTransferred;
			try ThreadMem.free(overlapped); catch (Throwable) {}

			static if (DEBUG) {
				if (dwError != 0)
					try writeln("Diretory watcher error: "~EWSAMessages[dwError.to!EWIN]); catch (Throwable) {}
			}
			try watcher.triggerChanged();
			catch (Exception e) {
				static if (DEBUG) {
					try writeln("Failed to trigger change"); catch (Throwable) {}
				}
			}
		}
	}
}

/// Information for a single Windows overlapped I/O request;
/// uses a freelist to minimize allocations.
struct AsyncOverlapped
{
	align (1):
	/// Required for Windows overlapped I/O requests
	OVERLAPPED overlapped;
	align:

	union
	{
		AsyncAcceptRequest* accept;
		AsyncReceiveRequest* receive;
		AsyncSendRequest* send;
	}

	@property void hEvent(HANDLE hEvent) @safe pure @nogc nothrow
	{ overlapped.hEvent = hEvent; }

	import libasync.internals.freelist;
	mixin FreeList!1_000;
}

nothrow extern(System)
{
	void onOverlappedReceiveComplete(error_t error, DWORD recvCount, AsyncOverlapped* overlapped, DWORD flags)
	{
		.tracef("onOverlappedReceiveComplete: error: %s, recvCount: %s, flags: %s", error, recvCount, flags);

		auto request = overlapped.receive;

		if (error == EWIN.WSA_OPERATION_ABORTED) {
			if (request.message) assumeWontThrow(NetworkMessage.free(request.message));
			assumeWontThrow(AsyncReceiveRequest.free(request));
			return;
		}

		auto socket = overlapped.receive.socket;
		auto eventLoop = &socket.m_evLoop.m_evLoop;
		if (eventLoop.m_status.code != Status.OK) return;

		eventLoop.m_status = StatusInfo.init;

		assumeWontThrow(AsyncOverlapped.free(overlapped));
		if (error == 0) {
			if (!request.message) {
				eventLoop.m_completedSocketReceives.insertBack(request);
				return;
			} else if (recvCount > 0 || !socket.connectionOriented) {
				request.message.count = request.message.count + recvCount;
				if (request.exact && !request.message.receivedAll) {
					eventLoop.submitRequest(request);
					return;
				} else {
					eventLoop.m_completedSocketReceives.insertBack(request);
					return;
				}
			} 
		} else if (recvCount > 0) {
			eventLoop.m_completedSocketReceives.insertBack(request);
			return;
		}

		assumeWontThrow(NetworkMessage.free(request.message));
		assumeWontThrow(AsyncReceiveRequest.free(request));

		if (error == WSAECONNRESET || error == WSAECONNABORTED || recvCount == 0) {
			socket.kill();
			socket.handleClose();
			return;
		}

		eventLoop.m_status.code = Status.ABORT;
		socket.kill();
		socket.handleError();
	}

	void onOverlappedSendComplete(error_t error, DWORD sentCount, AsyncOverlapped* overlapped, DWORD flags)
	{
		.tracef("onOverlappedSendComplete: error: %s, sentCount: %s, flags: %s", error, sentCount, flags);

		auto request = overlapped.send;

		if (error == EWIN.WSA_OPERATION_ABORTED) {
			assumeWontThrow(NetworkMessage.free(request.message));
			assumeWontThrow(AsyncSendRequest.free(request));
			return;
		}

		auto socket = overlapped.send.socket;
		auto eventLoop = &socket.m_evLoop.m_evLoop;
		if (eventLoop.m_status.code != Status.OK) return;

		eventLoop.m_status = StatusInfo.init;

		assumeWontThrow(AsyncOverlapped.free(overlapped));
		if (error == 0) {
			request.message.count = request.message.count + sentCount;
			assert(request.message.sent);
			eventLoop.m_completedSocketSends.insertBack(request);
			return;
		}

		assumeWontThrow(NetworkMessage.free(request.message));
		assumeWontThrow(AsyncSendRequest.free(request));

		if (error == WSAECONNRESET || error == WSAECONNABORTED) {
			socket.kill();
			socket.handleClose();
			return;
		}

		eventLoop.m_status.code = Status.ABORT;
		socket.kill();
		socket.handleError();
	}
}

enum WM_TCP_SOCKET = WM_USER+102;
enum WM_UDP_SOCKET = WM_USER+103;
enum WM_USER_EVENT = WM_USER+104;
enum WM_USER_SIGNAL = WM_USER+105;

nothrow:

__gshared Vector!(size_t, Malloc) gs_availID;
__gshared size_t gs_maxID;
__gshared core.sync.mutex.Mutex gs_mutex;

private size_t createIndex() {
	size_t idx;
	import std.algorithm : max;
	try {
		size_t getIdx() {
			if (!gs_availID.empty) {
				immutable size_t ret = gs_availID.back;
				gs_availID.removeBack();
				return ret;
			}
			return 0;
		}

		synchronized(gs_mutex) {
			idx = getIdx();
			if (idx == 0) {
				import std.range : iota;
				gs_availID.insert( iota(gs_maxID + 1, max(32, gs_maxID * 2 + 1), 1) );
				gs_maxID = gs_availID[$-1];
				idx = getIdx();
			}
		}
	} catch (Exception e) {
		assert(false, "Failed to generate necessary ID for Manual Event waiters: " ~ e.msg);
	}

	return idx;
}

void destroyIndex(AsyncTimer ctxt) {
	try {
		synchronized(gs_mutex) gs_availID ~= ctxt.id;
	}
	catch (Exception e) {
		assert(false, "Error destroying index: " ~ e.msg);
	}
}

shared static this() {

	try {
		if (!gs_mutex) {
			import core.sync.mutex;
			gs_mutex = new core.sync.mutex.Mutex;

			gs_availID.reserve(32);

			foreach (i; gs_availID.length .. gs_availID.capacity) {
				gs_availID.insertBack(i + 1);
			}

			gs_maxID = 32;
		}
	}
	catch (Throwable) {
		assert(false, "Couldn't reserve necessary space for available Manual Events");
	}

}

nothrow extern(System) {
	LRESULT wndProc(HWND wnd, UINT msg, WPARAM wparam, LPARAM lparam)
	{
		auto ptr = cast(void*)GetWindowLongPtrA(wnd, GWLP_USERDATA);
		if (ptr is null)
			return DefWindowProcA(wnd, msg, wparam, lparam);
		auto appl = cast(EventLoopImpl*)ptr;
		MSG obj = MSG(wnd, msg, wparam, lparam, DWORD.init, POINT.init);
		if (appl.onMessage(obj)) {
			static if (DEBUG) {
				if (appl.status.code != Status.OK && appl.status.code != Status.ASYNC) {
					import std.stdio : writeln;
					try { writeln(appl.error, ": ", appl.m_status.text); } catch (Throwable) {}
				}
			}
			return 0;
		}
		else return DefWindowProcA(wnd, msg, wparam, lparam);
	}

	BOOL PostMessageA(HWND hWnd, UINT Msg, WPARAM wParam, LPARAM lParam);

}