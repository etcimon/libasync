///
module libasync.bufferedtcp;

import std.algorithm : copy;
import std.array     : array, empty, front, popFront;
import std.range     : isInputRange, isOutputRange;

import memutils.circularbuffer : CircularBuffer;

import libasync.events;
import libasync.tcp    : AsyncTCPConnection, TCPEvent, TCPEventHandler;
import libasync.types  : StatusInfo;

///
final class BufferedTCPConnection(size_t size = 4092)
{
    ///
    alias OnEvent = void delegate(BufferedTCPConnection!size conn);
    ///
    alias OnRead  =
        void delegate(BufferedTCPConnection!size conn, in ubyte[] msg);

    private
    {
        AsyncTCPConnection asyncConn;

        OnEvent       onConnectCb;
        OnEvent       onCloseCb;
        OnEvent       onErrorCb;
        OnReadInfo[]  onReadCbs;
        OnWriteInfo[] onWriteCbs;

        CircularBuffer!(ubyte, size) readBuffer;
        CircularBuffer!(ubyte, size) writeBuffer;
        ubyte[] workBuffer = new ubyte[size];
    }

    ///
    this(
        EventLoop evl,
        fd_t preInitializedSocket = fd_t.init,
        in OnEvent onConnectCb = null,
        in OnEvent onCloseCb   = null,
        in OnEvent onErrorCb   = null)
    in
    {
        assert(evl !is null);
    }
    body
    {
        asyncConn = new AsyncTCPConnection(evl, preInitializedSocket);

        this.onConnectCb = onConnectCb;
        this.onCloseCb   = onCloseCb;
        this.onErrorCb   = onErrorCb;
    }

    ///
    this(
        AsyncTCPConnection conn,
        in OnEvent onConnectCb = null,
        in OnEvent onCloseCb   = null,
        in OnEvent onErrorCb   = null)
    in
    {
        assert(conn !is null);
    }
    body
    {
        asyncConn = conn;

        this.onConnectCb = onConnectCb;
        this.onCloseCb   = onCloseCb;
        this.onErrorCb   = onErrorCb;
    }

    ///
    @property bool hasError() const
    {
        return asyncConn.hasError;
    }

    /**
     * The status code is Status.ASYNC if the call is delayed (yield),
     * Status.ABORT if an unrecoverable socket/fd error occurs (throw), or
     * Status.ERROR if an internal error occured (assert).
     */
    @property StatusInfo status() const
    {
        return asyncConn.status;
    }

    /**
     * Returns: Human-readable error message from the underlying operating
     *          system.
     */
    @property string error() const
    {
        return asyncConn.error;
    }

    ///
    @property bool isConnected() const nothrow
    {
        return asyncConn.isConnected;
    }

    /**
     * Returns: true if this connection was accepted by an AsyncTCPListener
     *          instance.
     */
    @property bool inbound() const
    {
        return asyncConn.inbound;
    }

    /// Disables(true)/enables(false) nagle's algorithm (default:enabled).
    @property void noDelay(bool b)
    {
        asyncConn.noDelay(b);
    }

    /// Changes the default OS configurations for this underlying TCP Socket.
    bool setOption(T)(TCPOption op, in T val)
    {
        return asyncConn.setOption(op, val);
    }

    /// Returns the OS-specific structure of the internet address
    /// of the remote network adapter
    @property NetworkAddress peer() const
    {
        return asyncConn.peer;
    }

    /// Returns the OS-specific structure of the internet address
    /// for the local end of the connection.
    @property NetworkAddress local()
    {
        return asyncConn.local;
    }

    /// Sets the remote address as an OS-specific structure (only usable before connecting).
    @property void peer(NetworkAddress addr)
    {
        asyncConn.peer = addr;
    }

    /// (Blocking) Resolves the specified host and resets the peer to this address.
    /// Use AsyncDNS for a non-blocking resolver. (only usable before connecting).
    typeof(this) host(string hostname, size_t port)
    {
        asyncConn.host(hostname, port);
        return this;
    }

    /// Sets the peer to the specified IP address and port. (only usable before connecting).
    typeof(this) ip(string ip, size_t port)
    {
        asyncConn.ip(ip, port);
        return this;
    }

    /// Starts the connection by registering the associated callback handler in the
    /// underlying OS event loop.
    bool run(void delegate(TCPEvent) del)
    {
        TCPEventHandler handler;
        handler.conn = asyncConn;
        handler.del  = del;
        return run(handler);
    }

    private bool run(TCPEventHandler del)
    {
        return asyncConn.run(del);
    }

    /**
     * Receive data from the underlying stream. To be used when TCPEvent.READ
     * is received by the callback handler.
     * IMPORTANT: This must be called until is returns a lower value than the
     * buffer!
     */
    private uint recv()
    in
    {
        assert(isConnected, "No socket to operate on");
    }
    body
    {
        uint cnt = asyncConn.recv(workBuffer);
        if (cnt > 0)
            copy(workBuffer[0..cnt], &readBuffer);
        return cnt;
    }

    /**
     * Send data through the underlying stream by moving it into the OS buffer.
     */
    private uint send()
    in
    {
        assert(isConnected, "No socket to operate on");
    }
    body
    {
        copy(writeBuffer[], workBuffer);
        return asyncConn.send(workBuffer[0..writeBuffer.length].array);
    }

    /**
     * Removes the connection from the event loop, closing it if necessary, and
     * cleans up the underlying resources.
     */
    private bool kill(in bool forced = false)
    in
    {
        assert(isConnected);
    }
    body
    {
        bool ret = asyncConn.kill(forced);
        return ret;
    }

    ///
    void read(in size_t len, in OnRead onReadCb)
    {
        onReadCbs ~= OnReadInfo(len, onReadCb);
    }

    // Note: All buffers must be empty when returning from TCPEvent.READ
    private void onRead()
    {
        uint read;
        do read = recv();
        while (read == readBuffer.capacity);

        if (onReadCbs.empty)
            return;

        foreach (ref info; onReadCbs) with (info)
            if (readBuffer.length >= len)
            {
                cb(this, readBuffer[0..len].array);
                readBuffer.popFrontN(len);
                onReadCbs.popFront();
            }
            else
                break;
    }

    ///
    void write(R)(in R msg, in size_t len, in OnEvent cb = null)
    if (isInputRange!R)
    {
        writeBuffer.put(msg[0..len]);

        onWriteCbs ~= OnWriteInfo(len, cb);
        onWrite();
    }

    private void onWrite()
    {
        if (writeBuffer.length == 0)
            return;

        uint sent = send();
        writeBuffer.popFrontN(sent);

        foreach (ref info; onWriteCbs) with (info)
            if (sent >= len)
            {
                cb(this);
                onWriteCbs.popFront();
                sent -= len;
            }
            else
                break;
    }

    private void onConnect()
    {
        if (onConnectCb !is null)
            onConnectCb(this);
    }

    private void onError()
    {
        if (onErrorCb !is null)
            onErrorCb(this);
    }

    ///
    void close()
    {
        kill();
        onClose();
    }

    private void onClose()
    {
        if (onCloseCb !is null)
            onCloseCb(this);
    }

    ///
    void handle(TCPEvent ev)
    {
        final switch (ev)
        {
            case TCPEvent.CONNECT:
                onConnect();
                break;
            case TCPEvent.READ:
                onRead();
                break;
            case TCPEvent.WRITE:
                onWrite();
                break;
            case TCPEvent.CLOSE:
                onClose();
                break;
            case TCPEvent.ERROR:
                onError();
                break;
        }
    }

    private struct OnReadInfo
    {
        const size_t len;
        const OnRead cb;
    }

    private struct OnWriteInfo
    {
        const size_t len;
        const OnEvent cb;
    }
}
