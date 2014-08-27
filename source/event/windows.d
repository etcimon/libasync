module event.windows;

version (Windows):

import core.atomic;
import core.thread : Fiber;
import event.types;
import event.hashmap;
import std.container : Array;
import std.string : toStringz;
import std.conv : to;
import std.datetime : Duration, msecs, seconds;
import std.algorithm : min;
import std.c.windows.windows;
import std.c.windows.winsock;
import event.win32;
import std.traits : isIntegral;
import std.typecons : Tuple, tuple;
import std.utf : toUTFz;
import event.events;
pragma(lib, "ws2_32");
pragma(lib, "ole32.lib");
alias fd_t = SIZE_T;
alias error_t = EWIN;

package struct EventLoopImpl {
	pragma(msg, "Using Windows IOCP for events");

private:
	HashMap!(fd_t, TCPAcceptHandler)* m_connHandlers;
	HashMap!(fd_t, TCPEventHandler)* m_tcpHandlers;
	HashMap!(fd_t, TimerHandler)* m_timerHandlers;
	HashMap!(fd_t, UDPHandler)* m_udpHandlers;

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
	HANDLE[] m_waitObjects;
	ushort m_instanceId;
	StatusInfo m_status;
	error_t m_error = EWIN.WSA_OK;

package:
	@property bool started() const {
		return m_started;
	}
	bool init(EventLoop evl) 
	in { assert(!m_started); }
	body
	{

		m_status = StatusInfo.init;

		import event.memory : manualAllocator, FreeListObjectAlloc;
		import core.thread;
		try Thread.getThis().priority = Thread.PRIORITY_MAX;
		catch (Exception e) { assert(false, "Could not set thread priority"); }

		try {
			m_connHandlers = FreeListObjectAlloc!(typeof(*m_connHandlers)).alloc(manualAllocator());
			m_tcpHandlers = FreeListObjectAlloc!(typeof(*m_tcpHandlers)).alloc(manualAllocator());
			m_udpHandlers = FreeListObjectAlloc!(typeof(*m_udpHandlers)).alloc(manualAllocator());
			m_timerHandlers = FreeListObjectAlloc!(typeof(*m_timerHandlers)).alloc(manualAllocator());
		} catch (Exception e) { assert(false, "failed to setup allocator strategy in HashMap"); }
		m_evLoop = evl;
		shared static ushort i;
		m_instanceId = i;
		core.atomic.atomicOp!"+="(i, cast(ushort) 1);
		wstring inststr;
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
		try log("Window registered: " ~ m_hwnd.to!string); catch{}
		SetWindowLongPtrA(m_hwnd, GWLP_USERDATA, cast(ULONG_PTR)cast(void*)&this);
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
		assert(m_connHandlers !is null);
		assert(m_tcpHandlers !is null);
		assert(m_started);
	}
	body {
		DWORD msTimeout = cast(DWORD) min(timeout.total!"msecs", DWORD.max);
		/* 
		 * Waits until one or all of the specified objects are in the signaled state
		 * http://msdn.microsoft.com/en-us/library/windows/desktop/ms684245%28v=vs.85%29.aspx
		*/
		DWORD signal = MsgWaitForMultipleObjectsEx(
			cast(DWORD)0,
			null,
			msTimeout,
			QS_ALLEVENTS,								
			MWMO_ALERTABLE | MWMO_INPUTAVAILABLE		// MWMO_ALERTABLE: Wakes up to execute overlapped hEvent (i/o completion)
														// MWMO_INPUTAVAILABLE: Processes key/mouse input to avoid window ghosting
		);

		auto errors = 
			[	tuple(WAIT_TIMEOUT, Status.EVLOOP_TIMEOUT),		/* WAIT_TIMEOUT: Timeout was hit */
				tuple(WAIT_FAILED, Status.EVLOOP_FAILURE) ];	/* WAIT_FAILED: Failed to call MsgWait..() */

		if (catchErrors!"MsgWaitForMultipleObjectsEx"(signal, errors))
			return false; 
		
		MSG msg;
		while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE)) {
			m_status = StatusInfo.init;
			TranslateMessage(&msg);
			DispatchMessageW(&msg);
			if (m_status.code == Status.ERROR)
				return false;
		}
		return true;
	}

	fd_t run(AsyncTCPListener ctxt, TCPAcceptHandler del)
	{
		m_status = StatusInfo.init;
		fd_t fd = WSASocketW(cast(int)ctxt.local.family, SOCK_STREAM, IPPROTO_TCP, null, 0, WSA_FLAG_OVERLAPPED);
		
		if (catchSocketError!("run AsyncTCPConnection")(fd, INVALID_SOCKET))
			return 0;

		{
			BOOL on = true;
			int err = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, on.sizeof); // allows multi-threading workers
			if (catchSocketError!"SO_REUSEADDR"(err))
				return false;
		}

		// todo: defer accept

		if (ctxt.noDelay) {
			if (!setOption(fd, TCPOption.NODELAY, true))
				return 0;
		}

		if (initTCPListener(fd, ctxt))
		{
			try {
				(*m_connHandlers)[fd] = del;
			}
			catch (Exception e) {
				setInternalError!"m_connHandlers assign"(Status.ERROR, e.msg);
				closeSocket(fd, false);
				return 0;
			}
		}
		try log("Listener started FD#" ~ fd.to!string);
		catch{}
		return fd;
	}

	fd_t run(AsyncTCPConnection ctxt, TCPEventHandler del)
	in { 
		assert(ctxt.socket == fd_t.init); 
		assert(ctxt.peer.family != AF_UNSPEC);
	}
	body {
		m_status = StatusInfo.init;
		fd_t fd = WSASocketW(cast(int)ctxt.peer.family, SOCK_STREAM, IPPROTO_TCP, null, 0, WSA_FLAG_OVERLAPPED);

		log("Starting connection at: " ~ fd.to!string);
		if (catchSocketError!("run AsyncTCPConnection")(fd, INVALID_SOCKET))
			return 0;

		try {
			(*m_tcpHandlers)[fd] = del;
		}
		catch (Exception e) {
			setInternalError!"m_tcpHandlers assign"(Status.ERROR, e.msg);
			return 0;
		}

		debug {
			TCPEventHandler evh;
			try evh = m_tcpHandlers.get(fd);
			catch (Exception e) { log("Failed"); return 0; }
			assert( evh !is TCPEventHandler.init);
		}

		if (ctxt.noDelay) {
			if (!setOption(fd, TCPOption.NODELAY, true))
				return 0;
		}

		if (!initTCPConnection(fd, ctxt)) {
			try {
				log("Remove event handler for " ~ fd.to!string);
				m_tcpHandlers.remove(fd);
			}
			catch (Exception e) {
				setInternalError!"m_tcpHandlers remove"(Status.ERROR, e.msg);
			}

			closeSocket(fd, false);
			return 0;
		}


		try log("Client started FD#" ~ fd.to!string);
		catch{}
		return fd;
	}

	fd_t run(AsyncUDPSocket ctxt, UDPHandler del) {
		m_status = StatusInfo.init;
		fd_t fd = WSASocketW(cast(int)ctxt.local.family, SOCK_DGRAM, IPPROTO_UDP, null, 0, WSA_FLAG_OVERLAPPED);
		
		if (catchSocketError!("run AsyncUDPSocket")(fd, INVALID_SOCKET))
			return 0;

		if (initUDPSocket(fd, ctxt))
		{
			try {
				(*m_udpHandlers)[fd] = del;
			}
			catch (Exception e) {
				setInternalError!"m_udpHandlers assign"(Status.ERROR, e.msg);
				closeSocket(fd, false);
				return 0;
			}
		}

		try log("UDP Socket started FD#" ~ fd.to!string);
		catch{}

		return fd;
	}
	
	fd_t run(shared AsyncSignal ctxt) {
		m_status = StatusInfo.init;
		try log("Signal subscribed to: " ~ m_hwnd.to!string); catch {}
		return (cast(fd_t)m_hwnd);
	}

	fd_t run(AsyncNotifier ctxt) {
		m_status = StatusInfo.init;
		//try log("Running signal " ~ (cast(AsyncNotifier)ctxt).to!string); catch {}
		return cast(fd_t) m_hwnd;
	}
		
	fd_t run(AsyncTimer ctxt, TimerHandler del, Duration timeout) {
		m_status = StatusInfo.init;
		fd_t timer_id = ctxt.id;
		if (timer_id == fd_t.init) {
			timer_id = createIndex();
		}
		try log("Timer created: " ~ timer_id.to!string); catch {}

		BOOL err;
		try err = SetTimer(m_hwnd, timer_id, timeout.total!"msecs".to!uint, null);
		catch(Exception e) {
			setInternalError!"SetTimer"(Status.ERROR);
			return 0;
		}

		if (err == 0)
		{
			m_error = GetLastErrorSafe();
			m_status.code = Status.ERROR;
			m_status.text = "kill(AsyncTimer)";
			log(m_status);
			return 0;
		}

		if (m_timer.fd == fd_t.init) 
		{
			m_timer.fd = timer_id;
			m_timer.cb = del;
		}
		else {
			try
			{
				(*m_timerHandlers)[timer_id] = del;
			}
			catch (Exception e) {
				setInternalError!"HashMap assign"(Status.ERROR);
				return 0;
			}
		}

	
		return timer_id;
	}

	bool kill(AsyncTCPConnection ctxt, bool forced = false)
	{

		m_status = StatusInfo.init;
		fd_t fd = ctxt.socket;

		log("Killing socket "~ fd.to!string);
		try { 
			if ((ctxt.socket in *m_tcpHandlers) !is null)
				return closeSocket(fd, true, forced);
		} catch (Exception e) {
			setInternalError!"in m_tcpHandlers"(Status.ERROR, e.msg);
			return false;
		}

		return true;
	}

	bool kill(AsyncTCPListener ctxt)
	{
		m_status = StatusInfo.init;
		fd_t fd = ctxt.socket;
		try { 
			if ((ctxt.socket in *m_connHandlers) !is null) {
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


		BOOL err = KillTimer(m_hwnd, ctxt.id);
		if (err == 0)
		{
			m_error = GetLastErrorSafe();
			m_status.code = Status.ERROR;
			m_status.text = "kill(AsyncTimer)";
			return false;
		}

		destroyIndex(ctxt);

		if (m_timer.fd == ctxt.id) {
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
		nothrow bool errorHandler() {
			if (catchSocketError!"setOption:"(err)) {
				try m_status.text ~= option.to!string;
				catch (Exception e){ assert(false, "to!string conversion failure"); }
				return false;
			}
			
			return true;
		}


		static HashMap!(fd_t, tcp_keepalive)* kcache;

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
						kcache = new typeof(kcache)(defaultAllocator());

					tcp_keepalive kaSettings = kcache.get(fd, tcp_keepalive.init);
					tcp_keepalive sReturned;
					DWORD dwBytes;
					kaSettings.onoff = ULONG(1);
					if (kaSettings.keepalivetime == ULONG.init) {
						kaSettings.keepalivetime = 1000;
					}
					kaSettings.keepaliveinterval = value.total!"msecs".to!ULONG;
					kcache[fd] = kaSettings;
					err = WSAIoctl(fd, SIO_KEEPALIVE_VALS, &kaSettings, sizeof(tcp_keepalive), &sReturned, sizeof(sReturned), &dwBytes, NULL, NULL);

					return errorHandler();
				}
			case TCPOption.KEEPALIVE_DEFER: // wait ## seconds until start
				static if (!is(T == Duration))
					assert(false, "KEEPALIVE_DEFER value type must be Duration, not " ~ T.stringof);
				else {

					if (!kcache)
						kcache = new typeof(kcache)(defaultAllocator());

					tcp_keepalive kaSettings = kcache.get(fd, tcp_keepalive.init);
					tcp_keepalive sReturned;
					DWORD dwBytes;
					kaSettings.onoff = ULONG(1);
					if (kaSettings.keepaliveinterval == ULONG.init) {
						kaSettings.keepaliveinterval = 75*1000;
					}
					kaSettings.keepalivetime = value.total!"msecs".to!ULONG;

					kcache[fd] = kaSettings;
					err = WSAIoctl(fd, SIO_KEEPALIVE_VALS, &kaSettings, sizeof(tcp_keepalive), &sReturned, sizeof(sReturned), &dwBytes, NULL, NULL);

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

	uint read(in fd_t fd, ref ubyte[] data)
	{
		return 0;
	}

	uint write(in fd_t fd, in ubyte[] data)
	{
		return 0;
	}

	bool notify(T)(in fd_t fd, in T payload) 
	if (is(T == shared AsyncSignal) || is(T == AsyncNotifier))
	{

		m_status = StatusInfo.init;
		import std.conv;
		ubyte[4] ubwparam = ((cast(ubyte*)&payload)[0 .. 4]);
		ubyte[4] ublparam = ((cast(ubyte*)&payload)[4 .. 8]);
		WPARAM wparam = *cast(uint*)&ubwparam;
		LPARAM lparam = *cast(uint*)&ubwparam;	
		BOOL err;
		static if (is(T == AsyncNotifier))
			err = PostMessageA(cast(HWND)fd, WM_USER_SIGNAL, wparam, lparam);
		else
			err = PostMessageA(cast(HWND)fd, WM_USER_EVENT, wparam, lparam);
		try log("Sending notification to: " ~ (cast(HWND)fd).to!string); catch {}
		if (err == 0)
		{
			m_error = GetLastErrorSafe();
			m_status.code = Status.ERROR;
			m_status.text = "notify";
			return false;
		}
		return true;
	}

	uint recv(in fd_t fd, ref ubyte[] data)
	{
		m_status = StatusInfo.init;
		int ret = .recv(fd, cast(void*) data.ptr, cast(INT) data.length, 0);

		//try log("RECV " ~ ret.to!string ~ "B FD#" ~ fd.to!string); catch {}
		if (catchSocketError!".recv"(ret)) { // ret == -1
			if (m_error == WSAEWOULDBLOCK)
				m_status.code = Status.ASYNC;
			return 0; // TODO: handle some errors more specifically
		}
		m_status.code = Status.OK;

		return cast(uint) ret;
	}

	uint send(in fd_t fd, in ubyte[] data)
	{
		m_status = StatusInfo.init;
		//try log("SEND " ~ data.length.to!string ~ "B FD#" ~ fd.to!string);
		//catch{}
		int ret = .send(fd, cast(const(void)*) data.ptr, cast(INT) data.length, 0);

		if (catchSocketError!"send"(ret)) // ret == -1
			return 0; // TODO: handle some errors more specifically

		m_status.code = Status.ASYNC;
		return cast(uint) ret;
	}

	uint recvFrom(in fd_t fd, ref ubyte[] data, ref NetworkAddress addr)
	{
		m_status = StatusInfo.init;
		socklen_t addrLen;
		addr.family = AF_INET;
		int ret = .recvfrom(fd, cast(void*) data.ptr, cast(INT) data.length, 0, addr.sockAddr, &addrLen);

		if (addrLen > addr.sockAddrLen) {
			addr.family = AF_INET6;
		}
		
		try log("RECVFROM " ~ ret.to!string ~ "B"); catch {}
		if (catchSocketError!".recvfrom"(ret)) { // ret == -1
			if (m_error == WSAEWOULDBLOCK)
				m_status.code = Status.ASYNC;
			return 0; // TODO: handle some errors more specifically
		}
		m_status.code = Status.OK;
		
		return cast(uint) ret;
	}
	
	uint sendTo(in fd_t fd, in ubyte[] data, in NetworkAddress addr)
	{
		m_status = StatusInfo.init;
		try log("SENDTO " ~ data.length.to!string ~ "B");
		catch{}
		int ret = .sendto(fd, cast(void*) data.ptr, cast(INT) data.length, 0, addr.sockAddr, addr.sockAddrLen);
		
		if (catchSocketError!".sendTo"(ret)) { // ret == -1
			if (m_error == WSAEWOULDBLOCK)
				m_status.code = Status.ASYNC;
			return 0; // TODO: handle some errors more specifically
		}

		m_status.code = Status.OK;
		return cast(uint) ret;
	}
	


	void noDelay(in fd_t fd, bool b) {
		m_status = StatusInfo.init;
		setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &b, b.sizeof);
	}

	private bool closeRemoteSocket(fd_t fd, bool forced) {

		INT err;

		try log("Shutdown FD#" ~ fd.to!string);
		catch{}
		if (forced)
			err = shutdown(fd, SD_BOTH);
		else
			err = shutdown(fd, SD_SEND);

		try {
			TCPEventHandler* evh = fd in *m_tcpHandlers;
			if (evh && evh.conn.inbound) {
				import event.memory : FreeListObjectAlloc;
				try FreeListObjectAlloc!AsyncTCPConnection.free(evh.conn);
				catch(Exception e) { assert(false, "Failed to free resources"); }
				//log("Remove event handler for " ~ fd.to!string);
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
				if (fd in *m_connHandlers) {
					log("Removing connection handler for: " ~ fd.to!string);
					m_connHandlers.remove(fd);
				}
			}
			catch (Exception e) {
				setInternalError!"m_connHandlers.remove"(Status.ERROR);
				return false;
			}
		}
		else if (connected && !closeRemoteSocket(fd, forced)){
			// invokes m_tcpHandlers.remove()
			return false;
		}

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
	in {
		import event.validator;
		debug assert( validateIPv4(ipAddr) || validateIPv6(ipAddr), "Trying to connect to an invalid IP address");
	}
	body {
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
		try log(addr.toString());
		catch {}
		if( catchSocketError!"getAddressFromIP"(err) )
			return NetworkAddress.init;
		else assert(addrlen == addr.sockAddrLen);
		return addr;
	}

	NetworkAddress getAddressFromDNS(in string host, in ushort port = 0, in bool ipv6 = true, in bool tcp = true, in bool force = true)
	in { 
		import event.validator;
		debug assert(validateHost(host), "Trying to connect to an invalid domain");
	}
	body {
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
		if (err != EWIN.WSA_OK) {
			setInternalError!"GetAddrInfoW"(Status.ABORT, string.init, err);
			return NetworkAddress.init;
		}

		ubyte* pAddr = cast(ubyte*) infos.ai_addr;
		ubyte* data = cast(ubyte*) addr.sockAddr;
		data[0 .. infos.ai_addrlen] = pAddr[0 .. infos.ai_addrlen]; // perform bit copy
		FreeAddrInfoW(infos);
		try log("GetAddrInfoW Successfully resolved DNS to: " ~ addr.toAddressString());
		catch (Exception e){}
		return addr;
	}

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
	in {
		assert(m_connHandlers !is null);
		assert(m_tcpHandlers !is null);
	}
	body {
		m_status = StatusInfo.init;
		switch (msg.message) {
			case WM_TCP_SOCKET:
				auto evt = LOWORD(msg.lParam);
				auto err = HIWORD(msg.lParam);
				if (!onTCPEvent(evt, err, cast(fd_t)msg.wParam)) {
					try {
						TCPEventHandler cb = m_tcpHandlers.get(cast(fd_t)msg.wParam);
						cb(TCPEvent.ERROR);
					}
					catch (Exception e) {
						// An Error callback should never fail...
						setInternalError!"del@TCPEvent.ERROR"(Status.ERROR); 
						return false;
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
						return false;
					}
				}
				break;
			case WM_TIMER:
				TimerHandler cb;
				bool cached = (m_timer.fd == cast(fd_t)msg.wParam);
				try {
					if (cached)
						cb = m_timer.cb;
					else
						cb = m_timerHandlers.get(cast(fd_t)msg.wParam);
 
					cb();

					if (cb.ctxt.oneShot)
						kill(cb.ctxt);
				}
				catch (Exception e) {
					// An Error callback should never fail...
					setInternalError!"del@TimerHandler"(Status.ERROR);  
					return false;
				}

				break;
			case WM_USER_EVENT:
				ubyte[8] ptr;
				ptr[0 .. 4] = (cast(ubyte*)&msg.lParam)[0 .. 4];
				ptr[4 .. 8] = (cast(ubyte*)&msg.wParam)[4 .. 8];
				shared AsyncSignal ctxt = cast(shared AsyncSignal) *cast(void**) &ptr;
				try log("Got notification in : " ~ m_hwnd.to!string ~ " pointer: " ~ ptr.to!string); catch {}
				try {
					assert(ctxt.id != 0);
					ctxt.handler();
				}
				catch (Exception e) {
					setInternalError!"WM_USER_EVENT@handler"(Status.ERROR);  
					return false;
				}
				break;
			case WM_USER_SIGNAL:
				ubyte[8] ptr;
				ptr[0 .. 4] = (cast(ubyte*)&msg.lParam)[0 .. 4];
				ptr[4 .. 8] = (cast(ubyte*)&msg.wParam)[4 .. 8];
				AsyncNotifier ctxt = cast(AsyncNotifier) *cast(void**) &ptr;
				try {
					ctxt.handler();
				}
				catch (Exception e) {
					setInternalError!"WM_USER_SIGNAL@handler"(Status.ERROR);  
					return false;
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
		}	catch {}
		if (sock == 0) { // highly unlikely...
			setInternalError!"onUDPEvent"(Status.EVLOOP_FAILURE, "no socket defined");
			return false;
		}
		if (err) {
			setInternalError!"onUDPEvent"(Status.EVLOOP_FAILURE, string.init, cast(error_t)err);
			// todo: figure out how to send this in the callbacks without operating on the socket
			return false;
		}
		
		UDPHandler cb;
		switch(evt) {
			default: break;
			case FD_READ:
				try {
					log("READ FD#" ~ sock.to!string);
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
					log("WRITE FD#" ~ sock.to!string);
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
		}	catch {}
		if (sock == 0) { // highly unlikely...
			setInternalError!"onTCPEvent"(Status.EVLOOP_FAILURE, "no socket defined");
			return false;
		}
		if (err) {
			setInternalError!"onTCPEvent"(Status.EVLOOP_FAILURE, string.init, cast(error_t)err);
			// todo: figure out how to send this in the callbacks without operating on the socket
			return false;
		}

		TCPEventHandler cb;
		switch(evt) {
			default: break;
			case FD_ACCEPT:
				log("Accepting connection");
				NetworkAddress addr;
				addr.family = AF_INET;
				int addrlen = addr.sockAddrLen;
				fd_t csock = WSAAccept(sock, addr.sockAddr, &addrlen, null, 0);
				log("Connection accepted: " ~ csock.to!string);
				if (addrlen > addr.sockAddrLen)
					addr.family = AF_INET6;
				if (addrlen == typeof(addrlen).init) {
					setInternalError!"addrlen"(Status.ABORT);
					return false;
				}
				catchSocketError!"WSAAccept"(csock, INVALID_SOCKET);
				import event.memory : FreeListObjectAlloc;
				AsyncTCPConnection conn;
				try conn = FreeListObjectAlloc!AsyncTCPConnection.alloc(m_evLoop);
				catch (Exception e) { assert(false, "Failed allocation"); }
				conn.peer = addr;
				conn.socket = csock;
				conn.inbound = true;
				try {
					cb = (*m_connHandlers)[sock](conn); 
				} 
				catch(Exception e) {
					setInternalError!"onConnected"(Status.EVLOOP_FAILURE); 
					return false; 
				}
				try {
					(*m_tcpHandlers)[csock] = cb;
					log("ACCEPT&CONNECT FD#" ~ csock.to!string);
					cb(TCPEvent.CONNECT);
				}
				catch (Exception e) { 
					setInternalError!"m_tcpHandlers.opIndexAssign"(Status.ABORT); 
					return false; 
				}

				int ok = WSAAsyncSelect(csock, m_hwnd, WM_TCP_SOCKET, FD_CONNECT|FD_READ|FD_WRITE|FD_CLOSE);
				if ( catchSocketError!"WSAAsyncSelect"(ok) ) 
					return false;

				break;
			case FD_CONNECT:
				try {
					//log("CONNECT FD#" ~ sock.to!string);
					cb = m_tcpHandlers.get(sock);
					assert(cb != TCPEventHandler.init, "Socket " ~ sock.to!string ~ " could not yield a callback");
					cb(TCPEvent.CONNECT);
				} 
				catch(Exception e) {	
					setInternalError!"del@TCPEvent.CONNECT"(Status.ABORT);
					return false;
				}
				break;
			case FD_READ:
				try {
					log("READ FD#" ~ sock.to!string);
					cb = m_tcpHandlers.get(sock);
					assert(cb != TCPEventHandler.init, "Socket " ~ sock.to!string ~ " could not yield a callback");
					if (cb.conn.socket == 0)
						return true;
					cb(TCPEvent.READ);
				}
				catch (Exception e) {
					setInternalError!"del@TCPEvent.READ"(Status.ABORT); 
					return false;
				}
				break;
			case FD_WRITE:
				// todo: don't send the first write for consistency with epoll?

				try {
					//log("WRITE FD#" ~ sock.to!string);
					cb = m_tcpHandlers.get(sock);
					assert(cb != TCPEventHandler.init, "Socket " ~ sock.to!string ~ " could not yield a callback");
					if (cb.conn.socket == 0)
						return true;
					cb(TCPEvent.WRITE);
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
					//log("CLOSE FD#" ~ sock.to!string);
					if (sock in *m_tcpHandlers)
						(*m_tcpHandlers)[sock](TCPEvent.CLOSE);
					else
						connected = false;
				}
				catch (Exception e) {
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
		err = bind(fd, ctxt.local.sockAddr, ctxt.local.sockAddrLen);
		if (catchSocketError!"bind"(err)) {
			closesocket(fd);
			return false;
		}
		err = listen(fd, 128);
		if (catchSocketError!"listen"(err)) {
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

	bool initTCPListener(fd_t fd, AsyncTCPListener ctxt)
	in { 
		assert(m_threadId == GetCurrentThreadId());
		assert(ctxt.local !is NetworkAddress.init);
	}
	body {
		INT err;
		err = bind(fd, ctxt.local.sockAddr, ctxt.local.sockAddrLen);
		if (catchSocketError!"bind"(err)) {
			closesocket(fd);
			return false;
		}
		err = listen(fd, 128);
		if (catchSocketError!"listen"(err)) {
			closesocket(fd);
			return false;
		}
		err = WSAAsyncSelect(fd, m_hwnd, WM_TCP_SOCKET, FD_ACCEPT);
		if (catchSocketError!"WSAAsyncSelect"(err)) {
			closesocket(fd);
			return false;
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
		else assert(false, "Invalid NetworkAddress.family " ~ ctxt.peer.family.to!string);

		err = .bind(fd, bind_addr.sockAddr, bind_addr.sockAddrLen);
		if ( catchSocketError!"bind"(err) ) 
			return false;
		err = WSAAsyncSelect(fd, m_hwnd, WM_TCP_SOCKET, FD_CONNECT|FD_READ|FD_WRITE|FD_CLOSE);
		if ( catchSocketError!"WSAAsyncSelect"(err) ) 
			return false;
		err = .connect(fd, ctxt.peer.sockAddr, ctxt.peer.sockAddrLen);

		auto errors = [	tuple(cast(size_t) SOCKET_ERROR, EWIN.WSAEWOULDBLOCK, Status.ASYNC) ];		

		if (catchSocketErrorsEq!"connectEQ"(err, errors))
			return true;
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
					log(m_status);
					break;
				}
				m_error = GetLastErrorSafe();
				static if(LOG) log(m_status);
				return true;
			}
		}
		return false;
	}

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

	error_t WSAGetLastErrorSafe() {
		try {
			return cast(error_t) WSAGetLastError();
		} catch(Exception e) {
			return EWIN.ERROR_ACCESS_DENIED;
		}
	}

	error_t GetLastErrorSafe() {
		try {
			return cast(error_t) GetLastError();
		} catch(Exception e) {
			return EWIN.ERROR_ACCESS_DENIED;
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
				if ((m_error in EWSAMessages) !is null)
					writeln(" | Message: ", EWSAMessages[m_error]);
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

}
/**
		Represents a network/socket address. (taken from vibe.core.net)
*/
public struct NetworkAddress {
	import std.c.windows.winsock : sockaddr, sockaddr_in, sockaddr_in6;
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
enum WM_TCP_SOCKET = WM_USER+102;
enum WM_UDP_SOCKET = WM_USER+103;
enum WM_USER_EVENT = WM_USER+104;
enum WM_USER_SIGNAL = WM_USER+105;

nothrow:
size_t g_idxCapacity = 8;
Array!size_t g_idxAvailable;

// called on run
size_t createIndex() {
	size_t idx;
	import std.algorithm : min;
	import std.range : iota;
	try {
		
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
			g_idxAvailable.insert( iota(g_idxCapacity, min(32, g_idxCapacity * 2), 1) );
			g_idxCapacity = min(32, g_idxCapacity * 2);
			idx = getIdx();
		}
		
	} catch {}
	
	return idx;
}

void destroyIndex(AsyncTimer ctxt) {
	try {
		g_idxAvailable.insert(ctxt.id);		
	}
	catch (Exception e) {
		assert(false, "Error destroying index: " ~ e.msg);
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
		if (appl.onMessage(obj)) return 0;
		else return DefWindowProcA(wnd, msg, wparam, lparam);
	}

	BOOL PostMessageA(HWND hWnd, UINT Msg, WPARAM wParam, LPARAM lParam);

}
