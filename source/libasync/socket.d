module libasync.socket;

import std.typecons;
import std.socket;

import libasync.types;
import libasync.events;

final class AsyncSocket
{
private:
	Socket m_socket = void;

	OnConnectCb m_onConnect;
	OnCloseCb m_onClose;
	OnErrorCb m_onError;

	OnAcceptCb m_onAccept;

	bool m_connectionBased;

	alias OnReadCb = void delegate();
	alias OnWriteCb = void delegate();

package:
	EventLoop m_evLoop = void;

public:
	alias OnConnectCb = void delegate();
	alias OnCloseCb = void delegate();

	alias OnReceiveCb = void delegate(void[] data);
	alias OnSendCb = void delegate();
	alias OnAcceptCb = bool delegate(AsyncSocket client);
	alias OnErrorCb = void delegate();

nothrow:

private:
	this(EventLoop eventLoop, Socket socket)
	{
		m_evLoop = eventLoop;
		m_socket = socket;
	}

public:
	this(EventLoop eventLoop, AddressFamily af, SocketType type, ProtocolType protocol)
	{
		m_evLoop = eventLoop;
		try {
			m_socket = new Socket(af, type, protocol);
			m_socket.blocking = false;

			final switch (type) with (SocketType) {
				case STREAM: m_connectionBased = true; break;
				case SEQPACKET: m_connectionBased = true; break;

				case DGRAM: m_connectionBased = false; break;
				case RDM: m_connectionBased = false; break;

				case RAW: m_connectionBased = false; break;
			}
		}
		catch (Exception) {}
	}

	this(EventLoop eventLoop, AddressFamily af, SocketType type)
    {
        this(eventLoop, af, type, cast(ProtocolType) 0);
    }

	@property void onConnect(OnConnectCb onConnect)
	{ m_onConnect = onConnect; }

	@property void onClose(OnCloseCb onClose)
	{ m_onClose = onClose; }

	@property void onError(OnErrorCb onError)
	{ m_onError = onError; }

	@property void onAccept(OnAcceptCb onAccept)
	{ m_onAccept = onAccept; }

	mixin DefStatus;

version (Posix):

import std.array;
import std.container;

private:
	AsyncEvent m_event = void;

	struct RecvRequest
	{
		void[] buf;
		OnReceiveCb cb;
	}

	struct SendRequest
	{
		void[] buf;
		OnSendCb cb;
	}

	OnReadCb m_onRead;
	OnWriteCb m_onWrite;

	bool m_receiveReady;

	OnReceiveCb m_onReceive;
	void[] m_recvBuf;

	DList!RecvRequest m_recvRequests;
	DList!SendRequest m_sendRequests;

	// AsyncEvent is edge-triggered, not level-triggered,
	// so if we depend on a reactor pattern, we must read
	// ALL available bytes, as the READ event will only be generated
	// for new available data (so if e.g. our receive system call gets
	// interrupted by a signal after already having read some bytes,
	// there will never come a READ event for just the bytes remaining
	// available at that time - only when more bytes become available).
	// This will receive as much of the available bytes as fit in the
	// supplied buffer and return an appropriately sized slice to the latter,
	// so if the returned slice has the same size as the supplied buffer,
	// you will need to call receiveAvailable again.
	// NOTE: For socket types discarding available bytes on a recv system call
	//       should they not be able to fit into the supplied buffer, it is
	//       the caller's responsibility to provide a large enough buffer.
	void[] receiveAvailable(void[] buf)
	{
		if (!m_receiveReady) { return []; }

		auto recvBuf = buf;
		uint recvCount = void;

		do {
			recvCount = m_evLoop.recv(m_socket.handle, recvBuf);
			recvBuf = recvBuf[recvCount .. $];
		} while (recvCount > 0 && !recvBuf.empty);

		if (m_evLoop.status.code == Status.ASYNC) {
			m_receiveReady = false;
		}

		return buf[0 .. $ - recvBuf.length];
	}

	void blackhole() {}

	void receive()
	{
		m_receiveReady = true;
		if (m_onReceive is null) while (!m_recvRequests.empty && m_receiveReady) {
			auto recvRequest = m_recvRequests.front;
			auto received = receiveAvailable(recvRequest.buf);
			if (received.length > 0) {
				m_recvRequests.removeFront();
				try recvRequest.cb(received); catch {
					// TODO: Log this
				}
			}
		} else {
			auto received = receiveAvailable(m_recvBuf);
			if (received.length > 0) try { m_onReceive(received); } catch {
				// TODO: Log this
			}
		}
	}

	void send()
	{
		while (!m_sendRequests.empty) {
			auto sendRequest = m_sendRequests.front;
			auto buf = sendRequest.buf;

			uint sentCount = void;
			do {
				sentCount = m_evLoop.send(m_socket.handle, buf);
				if (m_evLoop.status.code == Status.ASYNC) {
					m_event.writeBlocked = true;
				}
				buf = buf[sentCount .. $];
			} while (!buf.empty && !m_event.writeBlocked);
			if (buf.empty) {
				m_sendRequests.removeFront();
				if (sendRequest.cb !is null) try sendRequest.cb(); catch {
					// TODO: Log this
				}
			}
			else {
				sendRequest.buf = buf;
				break;
			}
		}
	}

	void accept()
	{
		try while (true) {
			auto client = new AsyncSocket(m_evLoop, m_socket.accept());

			client.m_connectionBased = m_connectionBased;
			client.m_onRead = &receive;
			client.m_onWrite = &send;
			//if (client.m_connectionBased) client.m_event.stateful = true;

			if (m_onAccept(client)) {
				client.run();
				if (client.m_connectionBased) client.m_event.stateful = true;
			}
		} catch (SocketAcceptException) {
			// No more clients to accept
		} catch {
			// TODO: Handle this
		}
	}

public:
	bool run()
	{
		if (m_socket is null) return false;

		m_event = new AsyncEvent(m_evLoop, m_socket.handle);
		return m_event.run((code) {
			final switch (code) with (EventCode) {
				case CONNECT:
					if (m_onConnect !is null) m_onConnect();
					break;
				case CLOSE:
					if (m_onClose !is null) m_onClose();
					break;
				case READ:
					assert(m_onRead !is null);
					m_onRead();
					break;
				case WRITE:
					assert(m_onWrite !is null);
					m_onWrite();
					break;
				case ERROR:
					if (m_onError !is null) m_onError();
					else kill();
					break;
			}
		});
	}

	bool connect(Address to)
	{
		if (m_socket is null) return false;
		m_onRead = &receive;
		m_onWrite = &send;
		if (m_connectionBased) m_event.stateful = true;

		try {
			m_socket.connect(to);
			return true;
		} catch {
			m_event.kill();
			return false;
		}
	}
import std.stdio;
	bool bind(Address addr)
	{
		if (m_socket is null) return false;

		try {
			m_socket.bind(addr);
			return true;
		} catch (Exception e) {
			try writeln(e); catch {}
			m_event.kill();
			return false;
		}
	}

	bool listen(int backlog)
	{
		if (m_socket is null) return false;
		m_onRead = &accept;
		m_onWrite = &blackhole;

		try {
			m_socket.listen(backlog);
			return true;
		} catch {
			m_event.kill();
			return false;
		}
	}

	bool receive(void[] buf, OnReceiveCb onRecv)
	{
		if (m_onReceive !is null) { return false; }

		if (!m_recvRequests.empty) {
			m_recvRequests ~= RecvRequest(buf, onRecv);
			return true;
		}

		auto recvBuf = buf;
		uint recvCount = void;
		do {

			recvCount = m_evLoop.recv(m_socket.handle, recvBuf);
			recvBuf = recvBuf[recvCount .. $];
		} while (recvCount > 0 && !recvBuf.empty);

		if (buf.length == recvBuf.length) {
			m_recvRequests ~= RecvRequest(buf, onRecv);
		} else {
			try onRecv(buf[0 .. $ - recvBuf.length]); catch {
				// TODO: Log this
			}
		}
		return true;
	}

	void send(const(void)[] buf, OnSendCb onSent = null)
	{
		if (!m_sendRequests.empty) {
			m_sendRequests ~= SendRequest(buf.dup, onSent);
			return;
		}

		uint sentCount = void;
		do {
			sentCount = m_evLoop.send(m_socket.handle, buf);
			if (m_evLoop.status.code == Status.ASYNC) {
				m_event.writeBlocked = true;
			}
			buf = buf[sentCount .. $];
		} while (!buf.empty && !m_event.writeBlocked);

		if (!buf.empty) {
			m_sendRequests ~= SendRequest(buf.dup, onSent);
		} else {
			if (onSent !is null) try onSent(); catch {
				// TODO: Log this
			}
		}
	}

	bool startReceiving(void[] buf, OnReceiveCb onRecv)
	{
		if (!m_recvRequests.empty) { return false; }
		if (m_onReceive !is null && m_onReceive != onRecv) { return false; }
		m_recvBuf = buf;
		m_onReceive = onRecv;
		if (m_receiveReady) { receive(); }
		return true;
	}

	void stopReceiving()
	{
		if (m_onReceive !is null) {
			m_onReceive = null;
			m_recvBuf = null;
		}
	}

	/// Removes the socket from the event loop, shutting it down if necessary,
	/// and cleans up the underlying resources.
	bool kill()
	{
		if (m_onReceive !is null) stopReceiving();
		if (m_connectionBased && m_onClose !is null) try m_onClose(); catch {
			// TODO: Log this
		}
		return m_event.kill();
	}
}