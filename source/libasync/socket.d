module libasync.socket;

import std.array;
import std.exception;
import std.range;

import memutils.vector;

import libasync.events;
import libasync.internals.logging;
import libasync.internals.socket_compat;
import libasync.internals.freelist;
import libasync.internals.queue;

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

struct NetworkMessage
{
version (Posix) {
	import core.sys.posix.sys.socket : msghdr, iovec;

	alias Header        = msghdr;
	alias Content       = iovec;

	@property ubyte* contentStart() @trusted pure @nogc nothrow { return cast (ubyte*) m_content.iov_base; }
	@property void contentStart(ubyte* contentStart) @safe pure @nogc nothrow { m_content.iov_base = contentStart; }

	@property size_t contentLength() @trusted pure @nogc nothrow { return m_content.iov_len; }
	@property void contentLength(size_t contentLength) @safe pure @nogc nothrow { m_content.iov_len = contentLength; }
} else version (Windows) {
	import libasync.internals.win32 : WSABUF, DWORD;

	struct Header
	{
		sockaddr* msg_name;
		socklen_t msg_namelen;
		WSABUF*   msg_iov;
		size_t    msg_iovlen;
		DWORD     msg_flags;
	}

	alias Content     = WSABUF;

	@property ubyte* contentStart() @trusted pure @nogc nothrow { return m_content.buf; }
	@property void contentStart(ubyte* contentStart) @safe pure @nogc nothrow { m_content.buf = contentStart; }

	@property size_t contentLength() @trusted pure @nogc nothrow { return m_content.len; }
	@property void contentLength(size_t contentLength) @safe pure @nogc nothrow { m_content.len = contentLength; }
} else { static assert(false, "Platform unsupported"); }

	@property sockaddr* name() @trusted pure @nogc nothrow { return cast(sockaddr*) m_header.msg_name; }
	@property void name(sockaddr* name) @safe pure @nogc nothrow { m_header.msg_name = name; }

	@property socklen_t nameLength() @trusted pure @nogc nothrow { return m_header.msg_namelen; }
	@property void nameLength(socklen_t nameLength) @safe pure @nogc nothrow { m_header.msg_namelen = nameLength; }

	@property Content* buffers() @trusted pure @nogc nothrow { return m_header.msg_iov; }
	@property void buffers(Content* buffers) @safe pure @nogc nothrow { m_header.msg_iov = buffers; }

	@property typeof(m_header.msg_iovlen) bufferCount() @trusted pure @nogc nothrow { return m_header.msg_iovlen; }
	@property void bufferCount(typeof(m_header.msg_iovlen) bufferCount) @safe pure @nogc nothrow { m_header.msg_iovlen = bufferCount; }

	@property int flags() @trusted pure @nogc nothrow { return m_header.msg_flags; }
	@property void flags(int flags) @safe pure @nogc nothrow { m_header.msg_flags = flags; }

private:
	Header m_header;
	Content m_content;

	ubyte[] m_buffer;
	size_t m_count = 0;

package:
	@property Header* header() const @trusted pure @nogc nothrow
	{ return cast(Header*) &m_header; }

public:
	this(ubyte[] content, inout NetworkAddress* addr = null) @safe pure @nogc nothrow
	{
		if (addr is null) {
			name = null;
			nameLength = 0;
		} else {
			delegate () @trusted { name = cast(sockaddr*) addr.sockAddr; } ();
			nameLength = addr.sockAddrLen;
		}

		buffers = &m_content;
		bufferCount = 1;

		version (Posix) {
			m_header.msg_control = null;
			m_header.msg_controllen = 0;
		}

		flags = 0;

		m_buffer      = content;
		contentStart  = content.ptr;
		contentLength = content.length;
	}

	this(this) @safe pure @nogc nothrow
	{ buffers = &m_content; }

	@property size_t count() @safe pure @nogc nothrow
	{ return m_count; }

	@property void count(size_t count) @safe pure @nogc nothrow
	{
		m_count = count;
		auto content = m_buffer[count .. $];
		contentStart = content.ptr;
		contentLength = content.length;
	}

	@property bool hasAddress() @safe pure @nogc nothrow
	{ return name !is null; }

	@property bool receivedAny() @safe pure @nogc nothrow
	{ return m_count > 0; }

	@property bool receivedAll() @safe pure @nogc nothrow
	{ return m_count == m_buffer.length; }

	@property bool sent() @safe pure @nogc nothrow
	{ return m_count == m_buffer.length; }

	@property ubyte[] transferred() @safe pure @nogc nothrow
	{ return m_buffer[0 .. m_count]; }

	invariant
	{
		assert(m_count <= m_buffer.length, "Count of transferred bytes must not exceed the message buffer's length");
	}

	mixin FreeList!(1_000);
}

///
struct AsyncReceiveRequest
{
	AsyncSocket socket;       /// Socket to receive the message on
	NetworkMessage* message;  /// Storage to receive the message into
	OnComplete onComplete;    /// Called once the request completed successfully
	bool exact;               /// Whether the message's buffer should be filled completely

	alias OnComplete = void delegate(ubyte[] data);

	mixin FreeList!(1_000);
	mixin Queue;
}

///
struct AsyncSendRequest
{
	AsyncSocket socket;      // Socket to send the message on
	NetworkMessage* message; // The message to be sent
	OnComplete onComplete;   // Called once the request completed successfully

	alias OnComplete = void delegate();

	mixin FreeList!(1_000);
	mixin Queue;
}

/++
 + 
 +/
final class AsyncSocket
{
	invariant
	{
		// There are
		//  - connection-oriented, datagram-oriented sockets,
		//  - connection-oriented, not datagram-oriented (stream) sockets,
		//  - connectionless, datagram-oriented sockets
		// There are no connectionless, not datagram-oriented sockets
		assert(m_connectionOriented || m_datagramOriented);

		version (Posix) if (m_receiveContinuously) {
			auto requests = (cast(AsyncReceiveRequest.Queue) m_pendingReceives)[];
			assert(requests.empty || requests.dropOne.empty, "At most one receive request may be pending while receiving continuously");
		}
	}

private:
	fd_t m_preInitializedSocket;    /// If constructing from an existing socket, this holds it until initialization.

	fd_t m_socket = INVALID_SOCKET; /// The socket used internally.
	SocketInfo m_info;              /// Additional information about the socket.
	bool m_connectionOriented;      /// Whether this socket is connection-oriented.
	bool m_datagramOriented;        /// Whether this socket is datagram-oriented.

	/**
	 * Whether this socket has been put into passive mode.
	 * See_Also: listen
	 */
	bool m_passive;

	OnEvent m_onConnect; /// See_Also: onConnect
	OnEvent m_onClose;   /// See_Also: onClose
	OnError m_onError;   /// See_Also: onError
	OnAccept m_onAccept; /// See_Also: onAccept

	/**
	 * If disabled: Every call to $(D receiveMessage) will be processed only once.
	 * After enabling: The first call to $(D receiveMessage) will be processed repeatedly.
	 *                 Any further calls to $(D receiveMessage) are forbidden (while enabled).
	 */
	bool m_receiveContinuously;

	version (Posix) {
		package AsyncReceiveRequest.Queue m_pendingReceives; /// Queue of calls to $(D receiveMessage).
		package AsyncSendRequest.Queue m_pendingSends; /// Queue of requests initiated by $(D sendMessage).
	}

package:
	EventLoop m_evLoop; /// Event loop of the thread this socket was created by.

	void handleError() nothrow
	{ if (m_onError !is null) m_onError(); }

	void handleConnect()
	{ if (m_onConnect !is null) m_onConnect(); }

	void handleClose()
	{ if (m_onClose !is null) m_onClose(); }

	void handleAccept(typeof(this) peer) nothrow
	in { assert(m_onAccept !is null); }
	body { m_onAccept(peer); }

public:
	/// Generic callback type to handle events without additional parameters
	alias OnEvent = void delegate();
	///
	alias OnError = nothrow void delegate();
	/// Callback type to handle the successful acceptance of a peer on a
	/// socket on which `listen` succeeded
	alias OnAccept = nothrow void delegate(typeof(this) peer);

	///
	void receiveMessage(NetworkMessage* message, AsyncReceiveRequest.OnComplete onReceive, bool exact)
	in {
		assert(!m_passive, "Passive sockets cannot receive");
		assert(!m_connectionOriented || connected, "Established connection required");
		assert(!m_connectionOriented || !message.hasAddress, "Connected peer is already known through .remoteAddress");
		assert(!m_receiveContinuously || m_pendingReceives.empty, "Cannot receive message manually while receiving continuously");
		assert(m_connectionOriented || !exact, "Connectionless datagram sockets must receive one datagram at a time");
		assert(onReceive !is null, "Completion callback required");
		assert(message.m_buffer.length > 0, "Zero byte receives are not supported");
	} body {
		auto request = AsyncReceiveRequest.alloc(this, message, onReceive, exact);
		m_evLoop.submitRequest(request);
	}

	///
	void receive(ref ubyte[] buf, AsyncReceiveRequest.OnComplete onReceive)
	{
		auto message = NetworkMessage.alloc(buf);
		receiveMessage(message, onReceive, false);
	}

	///
	void receiveExactly(ref ubyte[] buf, AsyncReceiveRequest.OnComplete onReceive)
	{
		auto message = NetworkMessage.alloc(buf);
		receiveMessage(message, onReceive, true);
	}

	///
	void receiveFrom(ref ubyte[] buf, ref NetworkAddress from, AsyncReceiveRequest.OnComplete onReceive)
	{
		auto message = NetworkMessage.alloc(buf, &from);
		receiveMessage(message, onReceive, false);
	}

	///
	void sendMessage(NetworkMessage* message, AsyncSendRequest.OnComplete onSend)
	in {
		assert(!m_passive, "Passive sockets cannot receive");
		assert(!m_connectionOriented || connected, "Established connection required");
		assert(!m_connectionOriented || !message.hasAddress, "Connected peer is already known through .remoteAddress");
		assert(m_connectionOriented || { remoteAddress; return true; }().ifThrown(false) || message.hasAddress, "Remote address required");
		assert(onSend !is null, "Completion callback required");
	} body {
		auto request = AsyncSendRequest.alloc(this, message, onSend);
		m_evLoop.submitRequest(request);
	}

	///
	void send(in ubyte[] buf, OnEvent onSend)
	{
		auto message = NetworkMessage.alloc(cast(ubyte[]) buf);
		sendMessage(message, onSend);
	}

	///
	void sendTo(in ubyte[] buf, const ref NetworkAddress to, OnEvent onSend)
	{
		auto message = NetworkMessage.alloc(cast(ubyte[]) buf, &to);
		sendMessage(message, onSend);
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
	@property NetworkAddress localAddress() const @trusted
	{
		import libasync.internals.socket_compat : getsockname;

		NetworkAddress addr;
		auto addrLen = NetworkAddress.sockAddrMaxLen();
		if (SOCKET_ERROR == getsockname(m_socket, addr.sockAddr, &addrLen)) {
			throw new SocketOSException("Unable to obtain local socket address");
		}
		assert(addrLen <= addr.sockAddrLen,
			   "POSIX.1-2013 requires sockaddr_storage be able to store any socket address");
		assert(addr.family == m_info.family, "Inconsistent address family");
		return addr;
	}

	///
	@property NetworkAddress remoteAddress() const @trusted
	{
		import libasync.internals.socket_compat : getpeername;

		NetworkAddress addr;
		auto addrLen = NetworkAddress.sockAddrMaxLen();
		if (SOCKET_ERROR == getpeername(m_socket, addr.sockAddr, &addrLen)) {
			throw new SocketOSException("Unable to obtain local socket address");
		}
		assert(addrLen <= addr.sockAddrLen,
			   "POSIX.1-2013 requires sockaddr_storage be able to store any socket address");
		assert(addr.family == m_info.family, "Inconsistent address family");
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

package:
	mixin COSocketMixins;

	///
	@property SocketInfo info() const @safe pure @nogc
	{ return m_info; }

	@property fd_t preInitializedHandle() @safe pure @nogc
	{ return m_preInitializedSocket; }

	///
	@property void connectionOriented(bool connectionOriented) @safe pure @nogc
	{ m_connectionOriented = connectionOriented; }

	/// Retrieves and clears the most recent error on this socket
	@property auto lastError() const
	{
		import libasync.internals.socket_compat : SOL_SOCKET, SO_ERROR;
		int code;
		assumeWontThrow(getOption(SOL_SOCKET, SO_ERROR, code));
		return code;
	}

public:
	///
	this(EventLoop evLoop, int af, SocketType type, int protocol, fd_t socket = INVALID_SOCKET) @trusted
	in {
		assert(evLoop !is EventLoop.init);
		if (socket != INVALID_SOCKET) assert(socket.isSocket);
	} body {
		m_evLoop = evLoop;
		m_preInitializedSocket = socket;
		m_info = SocketInfo(af, type, protocol);
		m_connectionOriented = type.isConnectionOriented;
		m_datagramOriented = type.isDatagramOriented;

		version (Posix) {
			readBlocked = true;
			writeBlocked = true;
		}
	}

	/// The underlying OS socket descriptor
	@property fd_t handle() @safe pure @nogc
	{ return m_socket; }

	/// Whether this socket establishes a (stateful) connection to a remote peer.
	/// See_Also: isConnectionOriented
	@property bool connectionOriented() @safe pure @nogc
	{ return m_connectionOriented; }

	/// Whether this socket transceives datagrams.
	/// See_Also: isDatagramOriented
	@property bool datagramOriented() const @safe pure @nogc
	{ return m_datagramOriented; }

	/// Whether this socket has been put into passive mode.
	/// See_Also: listen
	@property bool passive() const @safe pure @nogc
	{ return m_passive; }

	/**
	 *  Convenience constructor for when there is only one protocol
	 *  supporting both $(D_PARAM af) and $(D_PARAM type).
	 */
	this(EventLoop eventLoop, int af, SocketType type) @safe
	{ this(eventLoop, af, type, 0); }

	/// Sets callback for when an active connection-oriented socket connects.
	@property void onConnect(OnEvent onConnect) @safe pure @nogc 
	in { assert(m_connectionOriented); }
	body { m_onConnect = onConnect; }

	/// Sets callback for when an active connection-oriented socket disconnects.
	@property void onClose(OnEvent onClose) @safe pure @nogc
	in { assert(m_connectionOriented); }
	body { m_onClose = onClose; }

	/// Sets callback for when a socket error has occurred.
	@property void onError(OnError onError) @safe pure @nogc
	{ m_onError = onError; }

	/// Sets callback for when a passive connection-oriented socket
	/// accepts a new connection request from a remote socket.
	@property void onAccept(OnAccept onAccept) @safe pure @nogc
	in { assert(m_connectionOriented); }
	body { m_onAccept = onAccept; }
	
	/// Creates the underlying OS socket - if necessary - and
	/// registers the event handler in the underlying OS event loop.
	bool run()
	in { assert(m_socket == INVALID_SOCKET); }
	body {
		m_socket = m_evLoop.run(this);
		return m_socket != INVALID_SOCKET;
	}

	/**
	 * Assigns the network address pointed to by $(D_PARAM addr),
	 * with $(D_PARAM addrlen) specifying the size, in bytes, of
	 * this address, as the local name of this socket.
	 * Returns: $(D true) if the binding was successful.
	 * See_Also:
	 *     localAddress, http://pubs.opengroup.org/onlinepubs/9699919799/functions/bind.html
	 */
	bool bind(sockaddr* addr, socklen_t addrlen)
	{ return m_evLoop.bind(this, addr, addrlen); }

	/**
	 * Assigns the network address pointed to by $(D_PARAM addr),
	 * with $(D_PARAM addrlen) specifying the size, n bytes, of
	 * this address, as the name of the remote socket.
	 * For connection-oriented sockets, also start establishing a
	 * connection with that socket and call $(D onConnect) once it has.
	 * Returns: $(D true) if the name was successfully assigned and
	 *          - for connection-oriented sockets - if the connection is
	 *          now being established.
	 * See_Also:
	 *     remoteAddress, onConnect, http://pubs.opengroup.org/onlinepubs/9699919799/functions/connect.html
	 */
	bool connect(sockaddr* addr, socklen_t addrlen)
	{ return m_evLoop.connect(this, addr, addrlen); }

	///
	bool bind(const ref NetworkAddress addr)
	{ return bind(cast(sockaddr*) addr.sockAddr, addr.sockAddrLen); }

	///
	bool connect(const ref NetworkAddress to)
	{ return connect(cast(sockaddr*) to.sockAddr, to.sockAddrLen); }

	///
	bool listen(int backlog)
	in { assert(m_onAccept !is null); }
	body
	{
		m_passive = true;
		return m_evLoop.listen(this, backlog);
	}

	@property bool receiveContinuously() const @safe pure @nogc
	{ return m_receiveContinuously; }

	///
	@property void receiveContinuously(bool toggle) @safe pure
	in {
		version (Posix) if (!m_receiveContinuously && toggle) assert(m_pendingReceives.empty, "Cannot start receiving continuously when there are still pending receives");
	} body {
		if (m_receiveContinuously == toggle) return;
		version (Posix) if (!toggle && !m_pendingReceives.empty) assumeWontThrow(m_pendingReceives.removeFront());
		m_receiveContinuously = toggle;
	}

	/// Removes the socket from the event loop, shutting it down if necessary,
	/// and cleans up the underlying resources.
	bool kill(bool forced = false)
	{
		receiveContinuously = false;
		scope (exit) m_socket = INVALID_SOCKET;
		return m_evLoop.kill(this, forced);
	}

	///
	@property bool alive() @safe @nogc {
		return m_socket.isSocket();
	}

	///
	mixin DefStatus;
}


/// Holds additional information about a socket.
struct SocketInfo
{
	int family;
	SocketType type;
	int protocol;
}

/**
 * Represents a network/socket address. (adapted from vibe.core.net)
 */
struct NetworkAddress
{
	import std.bitmanip: nativeToBigEndian, bigEndianToNative;

	import libasync.internals.socket_compat :
		sockaddr, sockaddr_storage,
		sockaddr_in, AF_INET,
		sockaddr_in6, AF_INET6;
	version (Posix) import libasync.internals.socket_compat :
		sockaddr_un, AF_UNIX;

	package union {
		sockaddr addr = { AF_UNSPEC };
		sockaddr_storage addr_storage = void;
		sockaddr_in addr_ip4 = void;
		sockaddr_in6 addr_ip6 = void;
		version (Posix) sockaddr_un addr_un = void;
	}

	this(sockaddr* addr, socklen_t addrlen) @trusted pure nothrow @nogc
	in {
		assert(addrlen <= sockaddr_storage.sizeof,
			   "POSIX.1-2013 requires sockaddr_storage be able to store any socket address");
	} body {
		import std.algorithm : copy;
		copy((cast(ubyte*) addr)[0 .. addrlen],
			 (cast(ubyte*) &addr_storage)[0 .. addrlen]);
	}

	this(Address address) @safe pure nothrow @nogc
	{ this(address.name, address.nameLen); }

	@property bool ipv6() const @safe pure nothrow @nogc
	{ return this.family == AF_INET6; }

	/** Family (AF_) of the socket address.
	 */
	@property ushort family() const @safe pure nothrow @nogc
	{ return addr.sa_family; }
	/// ditto
	@property void family(ushort val) pure @safe nothrow @nogc
	{ addr.sa_family = cast(ubyte) val; }

	/** The port in host byte order.
	 */
	@property ushort port()
	const @trusted @nogc pure nothrow {
		switch (this.family) {
			default: assert(false, "port() called for invalid address family.");
			case AF_INET: return bigEndianToNative!ushort((cast(ubyte*) &addr_ip4.sin_port)[0..2]);
			case AF_INET6: return bigEndianToNative!ushort((cast(ubyte*) &addr_ip6.sin6_port)[0..2]);
		}
	}
	/// ditto
	@property void port(ushort val)
	@trusted @nogc pure nothrow {
		switch (this.family) {
			default: assert(false, "port() called for invalid address family.");
			case AF_INET: addr_ip4.sin_port =  *cast(ushort*) nativeToBigEndian(val).ptr; break;
			case AF_INET6: addr_ip6.sin6_port = *cast(ushort*) nativeToBigEndian(val).ptr; break;
		}
	}

	/** A pointer to a sockaddr struct suitable for passing to socket functions.
	 */
	@property inout(sockaddr)* sockAddr() inout pure @safe @nogc nothrow { return &addr; }

	/** Size of the sockaddr struct that is returned by sockAddr().
	 */
	@property socklen_t sockAddrLen()
	const @safe @nogc pure nothrow {
		switch (this.family) {
			default: assert(false, "Unsupported address family");
			case AF_UNSPEC: return addr_storage.sizeof;
			case AF_INET: return addr_ip4.sizeof;
			case AF_INET6: return addr_ip6.sizeof;
			version (Posix) case AF_UNIX: return addr_un.sizeof;
		}
	}

	/++
	 + Maximum size of any sockaddr struct, regardless of address family.
	 +/
	static @property socklen_t sockAddrMaxLen()
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
			version (Posix) {
			case AF_UNIX:
				sink.formattedWrite("%s", fromStringz(cast(char*) addr_un.sun_path));
				break;
			}
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
			version (Posix) {
			case AF_UNIX:
				toAddressString(sink);
				break;
			}
		}
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