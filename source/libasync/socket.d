module libasync.socket;

import std.array;
import std.exception;

import memutils.vector;

import libasync.events;
import libasync.internals.logging;
import libasync.internals.socket_compat;


import std.socket : Address;
public import std.socket : SocketType, SocketOSException;

/// Returns `true` if the given type of socket is connection-oriented.
/// Standards: Conforms to IEEE Std 1003.1, 2013 Edition
bool isConnectionOriented(SocketType type) @safe pure nothrow @nogc
{
	final switch (type) with (SocketType) {
		case STREAM: return true;
		case SEQPACKET: return true;

		case DGRAM: return false;

		// Socket types not covered by POSIX.1-2013
		// are assumed to be connectionless.
		case RAW: return false;
		case RDM: return false;
	}
}

/// Returns `true` if the given type of socket is datagram-oriented.
/// Standards: Conforms to IEEE Std 1003.1, 2013 Edition
bool isDatagramOriented(SocketType type) @safe pure nothrow @nogc
{
	final switch (type) with (SocketType) {
		case STREAM: return false;

		case SEQPACKET: return true;
		case DGRAM: return true;

		// Socket types not covered by POSIX.1-2013
		// are assumed to be datagram-oriented.
		case RAW: return true;
		case RDM: return true;
	}
}

/++
 + 
 +/
final class AsyncSocket
{
private:
	/// The socket used internally
	fd_t m_socket = INVALID_SOCKET;
	/// If constructing from an existing socket,
	/// this holds it until initialization
	fd_t m_preInitializedSocket;

	/// Parameters for a socket system call
	alias SocketParams = Tuple!(int, "af", SocketType, "type", int, "protocol");
	/// See_Also: SocketParams
	SocketParams m_params;

	/// 
	bool m_connectionOriented;

	/// 
	bool m_datagramOriented;

	/// 
	/// See_Also: listen
	bool m_passive;

	/// See_Also: onEvent
	OnEvent m_onConnect, m_onClose, m_onError, m_onSend;
	/// See_Also: onReceive
	OnReceive m_onReceive;
	/// See_Also: onAccept
	OnAccept m_onAccept;

	///
	struct Message
	{
		ubyte[] buf;
		uint count;
		NetworkAddress* addr;
	}

	///
	struct RecvRequest
	{
		Message msg;

		OnReceive onComplete;
		bool exact;
	}

	///
	struct SendRequest
	{
		Message msg;

		OnEvent onComplete;
	}

	///
	bool m_continuousReceiving;

	///
	Vector!RecvRequest m_recvRequests;
	///
	Vector!SendRequest m_sendRequests;

package:
	///
	EventLoop m_evLoop;

	void handleError()
	{ if (m_onError !is null) m_onError(); }

	void handleConnect()
	{ if (m_onConnect !is null) m_onConnect(); }

	void handleClose()
	{ if (m_onClose !is null) m_onClose(); }

	void handleAccept(typeof(this) peer) nothrow
	in { assert(m_onAccept !is null); }
	body { m_onAccept(peer); }


	/++ Try to fulfil all requested receive operations, up until
	 +  there are no more bytes available in the OS receive buffer.
	 +  NOTE: The continuous receive mode is modeled as a single
	 +		receive request, which - in contrast to normal receive
	 +		requests - only gets removed from the queue when
	 +		the continous receive mode is stopped.
	 +/
	void processReceiveRequests()
	{
		while (!readBlocked && !m_recvRequests.empty) {
			auto request = &m_recvRequests.front();
			auto received = doReceive(request.msg);

			if (request.exact) with (request.msg) {
				count += received.length;
				if (count == buf.length) {
					if (!m_continuousReceiving) m_recvRequests.removeFront();
					else count = 0;
					request.onComplete(buf);
				} else break;
			} else if (received.length > 0
			           // These sockets allow zero-sized datagrams (e.g. UDP)
			           || !m_connectionOriented && m_datagramOriented) {
				if (!m_continuousReceiving) m_recvRequests.removeFront();
				request.onComplete(received);
			} else break;
		}
	}

	/++ Try to fulfil all requested send operations, up until
	 +  there is no more space available in the OS send buffer.
	 +/
	void processSendRequests()
	{
		while (!writeBlocked && !m_sendRequests.empty) {
			auto request = &m_sendRequests.front();
			auto sentCount = sendMessage(request.msg);

			request.msg.count += sentCount;
			if (request.msg.count  == request.msg.buf.length) {
				m_sendRequests.removeFront();
				request.onComplete();
			}
		}
	}

public:
	/// Generic callback type to handle events without additional parameters
	alias OnEvent = void delegate();
	/// Callback type to handle the completion of data reception
	alias OnReceive = void delegate(ubyte[] data);
	/// Callback type to handle the successful acceptance of a peer on a
	/// socket on which `listen` succeeded
	alias OnAccept = nothrow void delegate(typeof(this) peer);

	///
	void receive(ubyte[] buf, OnReceive onRecv, bool exact = false)
	in {
		assert(!m_passive, "Active socket required");
		if (m_connectionOriented) {
			assert(connected, "Established connection required");
		} else {
			assertNotThrown(remoteAddress, "Remote address required");
		}
		assert(!m_continuousReceiving, "Cannot receive manually while receiving continuously");
		assert(!m_datagramOriented || !exact, "Datagram sockets must receive one datagram at a time");
		assert(onRecv !is null, "Callback to use once reception has been completed required");
	}
	body {
		m_recvRequests ~= RecvRequest(Message(buf), onRecv, exact);
		processReceiveRequests();
	}

	///
	void receiveFrom(ubyte[] buf, ref NetworkAddress from, OnReceive onRecv)
	in {
		assert(!m_connectionOriented, "Connectionless socket required");
		assert(!m_continuousReceiving, "Cannot receive manually while receiving continuously");
		assert(onRecv !is null, "Callback to use once reception has been completed required");
	} body {
		m_recvRequests ~= RecvRequest(Message(buf, 0, &from), onRecv);
		processReceiveRequests();
	}

	///
	void send(ubyte[] buf, OnEvent onSend)
	in {
		assert(!m_passive, "Active socket required");
		if (m_connectionOriented) {
			assert(connected, "Established connection required");
		} else {
			assertNotThrown(remoteAddress, "Remote address required");
		}
		assert(onSend !is null, "Callback to use once transmission has been completed required");
	}
	body
	{
		m_sendRequests ~= SendRequest(Message(buf), onSend);
		processSendRequests();
	}

	void sendTo(ubyte[] buf, NetworkAddress to, OnEvent onSend)
	in {
		assert (!m_connectionOriented, "Connectionless socket required");
		assert(onSend !is null, "Callback to use once transmission has been completed required");
	} body {
		m_sendRequests ~= SendRequest(Message(buf, 0, &to), onSend);
		processSendRequests();
	}

	///
	void startReceiving(ubyte[] buf, OnReceive onRecv, bool exact = false)
	in {
		assert(!m_passive, "Active socket required");
		if (m_connectionOriented) {
			assert(connected, "Established connection required");
		} else if (m_datagramOriented) {
			assertNotThrown(localAddress, "Local address required");
			assert(!exact, "Datagram sockets must receive one datagram at a time");
		}
	} body {
		if (m_continuousReceiving) return;
		m_recvRequests ~= RecvRequest(Message(buf), onRecv, exact);
		m_continuousReceiving = true;
		if (!readBlocked) processReceiveRequests();
	}

	///
	void startReceivingFrom(ubyte[] buf, OnReceive onRecv, ref NetworkAddress addr)
	in {
		assert (!m_connectionOriented, "Connectionless socket required");
		if (m_datagramOriented) {
			assertNotThrown(localAddress, "Local address required");
		}
		assert(onRecv !is null, "Callback to use once reception has been completed required");
	} body {
		if (m_continuousReceiving) return;
		m_recvRequests ~= RecvRequest(Message(buf, 0, &addr), onRecv);
		m_continuousReceiving = true;
		if (!readBlocked) processSendRequests();
	}

	/// Same as `kill` on connection-less sockets; on connection-oriented sockets,
	/// additionally call the previously provided onClose callback.
	/// See_Also: kill, onClose
	bool close()
	{
		scope (exit) if (m_connectionOriented && !m_passive && m_onClose !is null) m_onClose();
		return kill();
	}

	///
	@property bool alive() {
		return m_socket.isSocket();
	}

	///
	NetworkAddress localAddress() const @trusted @property
	{
		import libasync.internals.socket_compat : getsockname;

		NetworkAddress addr;
		auto addrLen = NetworkAddress.sockAddrMaxLen();
		if (SOCKET_ERROR == getsockname(m_socket, addr.sockAddr, &addrLen)) {
			throw new SocketOSException("Unable to obtain local socket address");
		}
		assert(addrLen <= addr.sockAddrLen,
			   "POSIX.1-2013 requires sockaddr_storage be able to store any socket address");
		assert(addr.family == params.af, "Inconsistent address family");
		return addr;
	}

	///
	NetworkAddress remoteAddress() const @trusted @property
	{
		import libasync.internals.socket_compat : getpeername;

		NetworkAddress addr;
		auto addrLen = NetworkAddress.sockAddrMaxLen();
		if (SOCKET_ERROR == getpeername(m_socket, addr.sockAddr, &addrLen)) {
			throw new SocketOSException("Unable to obtain local socket address");
		}
		assert(addrLen <= addr.sockAddrLen,
			   "POSIX.1-2013 requires sockaddr_storage be able to store any socket address");
		assert(addr.family == params.af, "Inconsistent address family");
		return addr;
	}

	/// Get a socket option (taken from std.socket).
	/// Returns: The number of bytes written to $(D_PARAM result).
	//returns the length, in bytes, of the actual result - very different from getsockopt()
	int getOption(int level, int option, void[] result) @trusted const
	{
		import libasync.internals.socket_compat : getsockopt;

		socklen_t len = cast(socklen_t) result.length;
		if (SOCKET_ERROR == getsockopt(m_socket, level, option, result.ptr, &len)) {
			throw new SocketOSException("Unable to get socket option");
		}
		return len;
	}

	/// Common case of getting integer and boolean options (taken from std.socket).
	int getOption(int level, int option, out int result) @trusted const
	{ return getOption(level, option, (&result)[0 .. 1]); }

	/// Set a socket option (taken from std.socket).
	void setOption(int level, int option, void[] value) @trusted const
	{
		import libasync.internals.socket_compat : setsockopt;

		if (SOCKET_ERROR == setsockopt(m_socket, level, option, value.ptr, cast(uint) value.length)) {
			throw new SocketOSException("Unable to set socket option");
		}
	}

	/// Common case for setting integer and boolean options (taken from std.socket).
	void setOption(int level, int option, int value) @trusted const
	{ setOption(level, option, (&value)[0 .. 1]); }

nothrow:

private:

	/++
	 +  Fill the provided buffer with bytes currently available in
	 +  the OS receive buffer and return a slice to the received bytes.
	 +  If the provided buffer is large enough and there are no
	 +  recv/recvfrom/recvmsg system calls on this socket concurrent to this one,
	 +  then the returned slice contains all bytes that were available
	 +  in the OS receive buffer for this socket (in the sense that
	 +  any byte available in the OS receive buffer will generate a new
	 +  edge-triggered READ event).
	 +  Used only for sockets that are not message-based.
	 +  NOTES:
	 +  - If the OS receive buffer had more bytes available than fit in the
	 +	buffer, then the returned slice will have the same length
	 +	as the provided buffer. It is socket-type-specific what
	 +	happens to the bytes that did not fit into the provided buffer.
	 +  - If the OS receive buffer had less bytes available than could have
	 +	fit into the buffer, then the returned slice will be smaller then
	 +	the provided buffer.
	 +  - If the OS receive buffer had the same amount of bytes available
	 +	as the provided buffer had available space, then the returned slice
	 +	will have the same length as the provided buffer.
	 +/
	ubyte[] receiveAllAvailable(Message msg)
	{
		if (readBlocked) { return []; }

		auto recvBuf = msg.buf[msg.count .. $];
		uint recvCount = void;

		do {
			recvCount = m_evLoop.recv(m_socket, recvBuf);
			recvBuf = recvBuf[recvCount .. $];
		} while (recvCount > 0 && !recvBuf.empty);

		if (m_evLoop.status.code == Status.ASYNC) {
			readBlocked = true;
		}

		return msg.buf[0 .. $ - recvBuf.length];
	}

	/++
	 +  Fill the provided buffer with bytes of the datagram currently pending
	 +  in the OS receive buffer - if any - and return a slice to the received bytes.
	 +  Used only for sockets that are message-based.
	 +/
	ubyte[] receiveOneDatagram(Message msg)
	{
		if (readBlocked) { return []; }

		uint recvCount = void;
		if (msg.addr is null) recvCount = m_evLoop.recv(m_socket, msg.buf);
		else recvCount = m_evLoop.recvFrom(m_socket, msg.buf, *msg.addr);

		if (m_evLoop.status.code == Status.ASYNC) {
			readBlocked = true;
		}

		return msg.buf[0 .. recvCount];
	}

	ubyte[] delegate(Message) doReceive = void;

	/++
	 +  Fill the OS send buffer with bytes from the provided
	 +  socket until it becomes full, returning the number of bytes
	 +  transferred successfully.
	 +/
	uint sendMessage(Message msg)
	{
		auto sendBuf = msg.buf[msg.count .. $];
		uint sentCount = void;

		do {
			if (msg.addr is null) sentCount = m_evLoop.send(m_socket, sendBuf);
			else sentCount = m_evLoop.sendTo(m_socket, sendBuf, *msg.addr);

			sendBuf = sendBuf[sentCount .. $];
			if (m_evLoop.status.code == Status.ASYNC) {
				writeBlocked = true;
				break;
			}
		} while (sentCount > 0 && !sendBuf.empty);

		return sentCount;
	}

package:
	///
	mixin COSocketMixins;

	///
	SocketParams params() const @safe pure @nogc @property
	{ return m_params; }

	fd_t preInitializedHandle() @safe pure @nogc @property
	{ return m_preInitializedSocket; }

	///
	void connectionOriented(bool connectionOriented) @safe pure @nogc @property
	{ m_connectionOriented = connectionOriented; }

public:
	///
	this(EventLoop evLoop, int af, SocketType type, int protocol, fd_t socket = INVALID_SOCKET) @safe
	in
	{
		assert(evLoop !is EventLoop.init);
		if (socket != INVALID_SOCKET) assert(socket.isSocket);
	}
	body
	{
		m_evLoop = evLoop;
		m_preInitializedSocket = socket;
		m_params = SocketParams(af, type, protocol);
		m_connectionOriented = type.isConnectionOriented;
		m_datagramOriented = type.isDatagramOriented;

		if (m_datagramOriented) doReceive = &receiveOneDatagram;
		else doReceive = &receiveAllAvailable;

		assumeWontThrow(() @trusted {
			m_recvRequests.reserve(32);
			m_sendRequests.reserve(32);
		} ());
	}

	/// The underlying OS socket descriptor
	fd_t handle() @safe pure @nogc @property
	{ return m_socket; }

	/// Whether this socket establishes a (stateful) connection to a remote peer
	/// See_Also: isConnectionOriented
	bool connectionOriented() @safe pure @nogc @property
	{ return m_connectionOriented; }

	/// Whether this socket transceives datagrams
	/// See_Also: isDatagramOriented
	bool datagramOriented() @safe pure @nogc @property
	{ return m_datagramOriented; }

	///
	bool passive() const @safe pure @nogc @property
	{ return m_passive; }

	///
	this(EventLoop eventLoop, int af, SocketType type) @safe
	{ this(eventLoop, af, type, 0); }

	///
	void onConnect(OnEvent onConnect) @safe pure @nogc @property
	{ m_onConnect = onConnect; }

	///
	void onClose(OnEvent onClose) @safe pure @nogc @property
	{ m_onClose = onClose; }

	///
	void onError(OnEvent onError) @safe pure @nogc @property
	{ m_onError = onError; }

	///
	void onAccept(OnAccept onAccept) @safe pure @nogc @property
	{ m_onAccept = onAccept; }
	
	/// Creates the underlying OS socket - if necessary - and
	/// registers the event handler in the underlying OS event loop.
	bool run()
	in { assert(m_socket == INVALID_SOCKET); }
	body
	{
		m_socket = m_evLoop.run(this);
		return m_socket != INVALID_SOCKET;
	}

	///
	bool bind(sockaddr* addr, socklen_t addrlen)
	{ return m_evLoop.bind(this, addr, addrlen); }

	///
	bool connect(sockaddr* addr, socklen_t addrlen)
	{ return m_evLoop.connect(this, addr, addrlen); }

	///
	bool bind(NetworkAddress addr)
	{ return bind(addr.sockAddr, addr.sockAddrLen); }

	///
	bool connect(NetworkAddress to)
	{ return bind(to.sockAddr, to.sockAddrLen); }

	///
	bool bind(Address addr)
	{ return bind(addr.name, addr.nameLen); }

	///
	bool connect(Address to)
	{ return bind(to.name, to.nameLen); }

	///
	bool listen(int backlog)
	in { assert(m_onAccept !is null); }
	body
	{
		m_passive = true;
		return m_evLoop.listen(this, backlog);
	}

	///
	void stopReceiving()
	{
		if (!m_continuousReceiving) return;
		assumeWontThrow(m_recvRequests.removeFront);
		m_continuousReceiving = false;
	}

	/// Removes the socket from the event loop, shutting it down if necessary,
	/// and cleans up the underlying resources.
	bool kill(bool forced = false)
	{
		stopReceiving();
		return m_evLoop.kill(this, forced);
	}

	///
	mixin DefStatus;
}

/++
 + Represents a network/socket address. (adapted from vibe.core.net)
 +/
struct NetworkAddress
{
	import libasync.internals.socket_compat :
		sockaddr, sockaddr_storage,
		sockaddr_in, AF_INET,
		sockaddr_in6, AF_INET6;
	version (Posix) import libasync.internals.socket_compat :
		sockaddr_un, AF_UNIX;

	package union {
		sockaddr addr;
		sockaddr_storage addr_storage;
		sockaddr_in addr_ip4;
		sockaddr_in6 addr_ip6;
		version (Posix) sockaddr_un addr_un;
	}

	this(Address address) @trusted pure nothrow @nogc
	in {
		assert(address.nameLen <= sockaddr_storage.sizeof,
			   "POSIX.1-2013 requires sockaddr_storage be able to store any socket address");
	} body {
		import std.algorithm : copy;
		copy((cast(ubyte*) address.name)[0 .. address.nameLen],
			 (cast(ubyte*) &addr_storage)[0 .. address.nameLen]);
	}
 
	@property bool ipv6() const @safe pure nothrow @nogc
	{ return this.family == AF_INET6; }

	/** Family (AF_) of the socket address.
	 */
	@property ushort family() const @safe pure nothrow @nogc
	{ return addr.sa_family; }
	/// ditto
	@property void family(ushort val) pure @safe nothrow @nogc
	{ addr.sa_family = cast(ubyte)val; }

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
	@property uint sockAddrLen()
	const pure nothrow {
		switch (this.family) {
			default: assert(false, "Unsupported address family");
			case AF_INET: return addr_ip4.sizeof;
			case AF_INET6: return addr_ip6.sizeof;
			version (Posix) case AF_UNIX: return addr_un.sizeof;
		}
	}

	/++
	 + Maximum size of any sockaddr struct, regardless of address family.
	 +/
	static @property uint sockAddrMaxLen()
	pure nothrow { return sockaddr_storage.sizeof; }

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
		auto ret = appender!string();
		ret.reserve(40);
		toAddressString(str => ret.put(str));
		return ret.data;
	}
	/// ditto
	void toAddressString(scope void delegate(const(char)[]) @safe sink)
	const {
		import std.array : appender;
		import std.format : formattedWrite;
		import std.string : fromStringz;

		ubyte[2] _dummy = void; // Workaround for DMD regression in master

		switch (this.family) {
			default: assert(false, "toAddressString() called for invalid address family.");
			case AF_INET:
				ubyte[4] ip = () @trusted { return (cast(ubyte*) &addr_ip4.sin_addr.s_addr)[0 .. 4]; } ();
				sink.formattedWrite("%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
				break;
			case AF_INET6:
				ubyte[16] ip = addr_ip6.sin6_addr.s6_addr;
				foreach (i; 0 .. 8) {
					if (i > 0) sink(":");
					_dummy[] = ip[i*2 .. i*2+2];
					sink.formattedWrite("%x", bigEndianToNative!ushort(_dummy));
				}
				break;
			version (Posix) case AF_UNIX:
				sink.formattedWrite("%s", fromStringz(cast(char*) addr_un.sun_path));
				break;
		}
	}

	/** Returns a full string representation of the address, including the port number.
	*/
	string toString()
	const {
		import std.array : appender;
		auto ret = appender!string();
		toString(str => ret.put(str));
		return ret.data;
	}
	/// ditto
	void toString(scope void delegate(const(char)[]) @safe sink)
	const {
		import std.format : formattedWrite;
		switch (this.family) {
			default: assert(false, "toString() called for invalid address family.");
			case AF_INET:
				toAddressString(sink);
				sink.formattedWrite(":%s", port);
				break;
			case AF_INET6:
				sink("[");
				toAddressString(sink);
				sink.formattedWrite("]:%s", port);
				break;
			version (Posix) case AF_UNIX:
				toAddressString(sink);
				break;
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

/// Taken from std.socket, as it is not part of its documented API
// Needs to be public so that SocketOSException can be thrown outside of
// std.socket (since it uses it as a default argument), but it probably doesn't
// need to actually show up in the docs, since there's not really any public
// need for it outside of being a default argument.
string formatSocketError(int err) @trusted nothrow
{
	version(Posix)
	{
		import core.stdc.string : strerror_r, strlen;
		import std.conv : to;

		char[80] buf;
		const(char)* cs;

		version (CRuntime_Glibc)
		{
			cs = strerror_r(err, buf.ptr, buf.length);
		}
		else version (OSX)
		{
			auto errs = strerror_r(err, buf.ptr, buf.length);
			if (errs == 0)
				cs = buf.ptr;
			else
				return "Socket error " ~ to!string(err);
		}
		else version (FreeBSD)
		{
			auto errs = strerror_r(err, buf.ptr, buf.length);
			if (errs == 0)
				cs = buf.ptr;
			else
				return "Socket error " ~ to!string(err);
		}
		else version (NetBSD)
		{
			auto errs = strerror_r(err, buf.ptr, buf.length);
			if (errs == 0)
				cs = buf.ptr;
			else
				return "Socket error " ~ to!string(err);
		}
		else version (Solaris)
		{
			auto errs = strerror_r(err, buf.ptr, buf.length);
			if (errs == 0)
				cs = buf.ptr;
			else
				return "Socket error " ~ to!string(err);
		}
		else version (CRuntime_Bionic)
		{
			auto errs = strerror_r(err, buf.ptr, buf.length);
			if (errs == 0)
				cs = buf.ptr;
			else
				return "Socket error " ~ to!string(err);
		}
		else
			static assert(0);

		auto len = strlen(cs);

		if (cs[len - 1] == '\n')
			len--;
		if (cs[len - 1] == '\r')
			len--;
		return cs[0 .. len].idup;
	}
	else version(Windows)
	{
		import std.windows.syserror : sysErrorString;

		return sysErrorString(err);
	} else {
		return "Socket error " ~ to!string(err);
	}
}

version (Posix)
{
	enum SOCKET_ERROR = -1;
	enum INVALID_SOCKET = -1;
} else version (Windows) {
	import core.sys.windows.winsock2 : SOCKET_ERROR, INVALID_SOCKET;
}

///
bool isSocket(fd_t fd) @trusted @nogc nothrow
{
	import libasync.internals.socket_compat : getsockopt, SOL_SOCKET, SO_TYPE;

	int type;
	socklen_t typesize = cast(socklen_t) type.sizeof;
	return SOCKET_ERROR != getsockopt(fd, SOL_SOCKET, SO_TYPE, cast(char*) &type, &typesize);
}