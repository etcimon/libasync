/// [internal]
module libasync.internals.win32;

version(Windows):

public import core.sys.windows.windows;
public import core.sys.windows.windows;
public import core.sys.windows.winsock2;
public import core.sys.windows.com : GUID;

extern(System) nothrow
{
	enum HWND HWND_MESSAGE = cast(HWND)-3;
	enum {
		GWLP_WNDPROC = -4,
		GWLP_HINSTANCE = -6,
		GWLP_HWNDPARENT = -8,
		GWLP_USERDATA = -21,
		GWLP_ID = -12,
	}

	version(Win32){ // avoiding linking errors with out-of-the-box dmd
		alias SetWindowLongA SetWindowLongPtrA;
		alias GetWindowLongA GetWindowLongPtrA;
	} else {
		LONG_PTR SetWindowLongPtrA(HWND hWnd, int nIndex, LONG_PTR dwNewLong);
		LONG_PTR GetWindowLongPtrA(HWND hWnd, int nIndex);
	}
	LONG_PTR SetWindowLongPtrW(HWND hWnd, int nIndex, LONG_PTR dwNewLong);
	LONG_PTR GetWindowLongPtrW(HWND hWnd, int nIndex);
	LONG_PTR SetWindowLongA(HWND hWnd, int nIndex, LONG dwNewLong);
	LONG_PTR GetWindowLongA(HWND hWnd, int nIndex);

	alias void function(DWORD, DWORD, OVERLAPPED*) LPOVERLAPPED_COMPLETION_ROUTINE;

	HANDLE CreateEventW(SECURITY_ATTRIBUTES* lpEventAttributes, BOOL bManualReset, BOOL bInitialState, LPCWSTR lpName);
	BOOL PostThreadMessageW(DWORD idThread, UINT Msg, WPARAM wParam, LPARAM lParam);
	DWORD MsgWaitForMultipleObjectsEx(DWORD nCount, const(HANDLE) *pHandles, DWORD dwMilliseconds, DWORD dwWakeMask, DWORD dwFlags);
	static if (!is(typeof(&CreateFileW))) BOOL CloseHandle(HANDLE hObject);
	static if (!is(typeof(&CreateFileW))) HANDLE CreateFileW(LPCWSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, LPSECURITY_ATTRIBUTES lpSecurityAttributes,
					   DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, HANDLE hTemplateFile);
	BOOL WriteFileEx(HANDLE hFile, LPCVOID lpBuffer, DWORD nNumberOfBytesToWrite, OVERLAPPED* lpOverlapped,
					 LPOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine);
	BOOL ReadFileEx(HANDLE hFile, LPVOID lpBuffer, DWORD nNumberOfBytesToRead, OVERLAPPED* lpOverlapped,
					LPOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine);
	BOOL GetFileSizeEx(HANDLE hFile, long *lpFileSize);
	BOOL SetEndOfFile(HANDLE hFile);
	BOOL GetOverlappedResult(HANDLE hFile, OVERLAPPED* lpOverlapped, DWORD* lpNumberOfBytesTransferred, BOOL bWait);
	BOOL WSAGetOverlappedResult(SOCKET s, OVERLAPPED* lpOverlapped, DWORD* lpcbTransfer, BOOL fWait, DWORD* lpdwFlags);
	BOOL PostMessageW(HWND hwnd, UINT msg, WPARAM wPara, LPARAM lParam);
	BOOL PostThreadMessageA(HWND hwnd, UINT msg, WPARAM wPara, LPARAM lParam);

	HANDLE GetStdHandle(DWORD nStdHandle);
	bool ReadFile(HANDLE hFile, void* lpBuffer, DWORD nNumberOfBytesRead, DWORD* lpNumberOfBytesRead, OVERLAPPED* lpOverlapped);

	static if (__VERSION__ < 2065) {
		BOOL PeekMessageW(MSG *lpMsg, HWND hWnd, UINT wMsgFilterMin, UINT wMsgFilterMax, UINT wRemoveMsg);
		LONG DispatchMessageW(MSG *lpMsg);

		enum {
			ERROR_ALREADY_EXISTS = 183,
			ERROR_IO_PENDING = 997
		}
	}

	struct FILE_NOTIFY_INFORMATION {
		DWORD NextEntryOffset;
		DWORD Action;
		DWORD FileNameLength;
		WCHAR[1] FileName;
	}

	BOOL ReadDirectoryChangesW(HANDLE hDirectory, void* lpBuffer, DWORD nBufferLength, BOOL bWatchSubtree, DWORD dwNotifyFilter, LPDWORD lpBytesReturned, void* lpOverlapped, void* lpCompletionRoutine);
	HANDLE FindFirstChangeNotificationW(LPCWSTR lpPathName, BOOL bWatchSubtree, DWORD dwNotifyFilter);
	HANDLE FindNextChangeNotification(HANDLE hChangeHandle);

	enum{
		WSAPROTOCOL_LEN  = 255,
		MAX_PROTOCOL_CHAIN = 7,
	};

	enum WSA_IO_INCOMPLETE = 996;
	enum WSA_IO_PENDING = 997;

	struct WSAPROTOCOL_INFOW {
		DWORD            dwServiceFlags1;
		DWORD            dwServiceFlags2;
		DWORD            dwServiceFlags3;
		DWORD            dwServiceFlags4;
		DWORD            dwProviderFlags;
		GUID             ProviderId;
		DWORD            dwCatalogEntryId;
		WSAPROTOCOLCHAIN ProtocolChain;
		int              iVersion;
		int              iAddressFamily;
		int              iMaxSockAddr;
		int              iMinSockAddr;
		int              iSocketType;
		int              iProtocol;
		int              iProtocolMaxOffset;
		int              iNetworkByteOrder;
		int              iSecurityScheme;
		DWORD            dwMessageSize;
		DWORD            dwProviderReserved;
		WCHAR[WSAPROTOCOL_LEN+1] szProtocol;
	};

	struct WSAPROTOCOLCHAIN {
		int ChainLen;
		DWORD[MAX_PROTOCOL_CHAIN] ChainEntries;
	};

	struct WSABUF {
		size_t   len;
		ubyte *buf;
	}

	struct WSAMSG {
        sockaddr*  name;
        int        namelen;
        WSABUF*    lpBuffers;
        DWORD      dwBufferCount;
        WSABUF     Control;
        DWORD      dwFlags;
    }

	struct WSAOVERLAPPEDX {
		ULONG_PTR Internal;
		ULONG_PTR InternalHigh;
		union {
			struct {
				DWORD Offset;
				DWORD OffsetHigh;
			}
			PVOID  Pointer;
		}
		HANDLE hEvent;
	}

	enum {
		WSA_FLAG_OVERLAPPED = 0x01
	}

	enum {
		FD_READ = 0x0001,
		FD_WRITE = 0x0002,
		FD_OOB = 0x0004,
		FD_ACCEPT = 0x0008,
		FD_CONNECT = 0x0010,
		FD_CLOSE = 0x0020,
		FD_QOS = 0x0040,
		FD_GROUP_QOS = 0x0080,
		FD_ROUTING_INTERFACE_CHANGE = 0x0100,
		FD_ADDRESS_LIST_CHANGE = 0x0200
	}

	struct ADDRINFOEXW {
		int ai_flags;
		int ai_family;
		int ai_socktype;
		int ai_protocol;
		size_t ai_addrlen;
		LPCWSTR ai_canonname;
		sockaddr* ai_addr;
		void* ai_blob;
		size_t ai_bloblen;
		GUID* ai_provider;
		ADDRINFOEXW* ai_next;
	}

	struct ADDRINFOA {
		int ai_flags;
		int ai_family;
		int ai_socktype;
		int ai_protocol;
		size_t ai_addrlen;
		LPSTR ai_canonname;
		sockaddr* ai_addr;
		ADDRINFOA* ai_next;
	}

	struct ADDRINFOW {
		int ai_flags;
		int ai_family;
		int ai_socktype;
		int ai_protocol;
		size_t ai_addrlen;
		LPWSTR ai_canonname;
		sockaddr* ai_addr;
		ADDRINFOW* ai_next;
	}

	enum {
		NS_ALL = 0,
		NS_DNS = 12
	}

	struct WSAPROTOCOL_INFO {
		DWORD            dwServiceFlags1;
		DWORD            dwServiceFlags2;
		DWORD            dwServiceFlags3;
		DWORD            dwServiceFlags4;
		DWORD            dwProviderFlags;
		GUID             ProviderId;
		DWORD            dwCatalogEntryId;
		WSAPROTOCOLCHAIN ProtocolChain;
		int              iVersion;
		int              iAddressFamily;
		int              iMaxSockAddr;
		int              iMinSockAddr;
		int              iSocketType;
		int              iProtocol;
		int              iProtocolMaxOffset;
		int              iNetworkByteOrder;
		int              iSecurityScheme;
		DWORD            dwMessageSize;
		DWORD            dwProviderReserved;
		CHAR[WSAPROTOCOL_LEN+1] szProtocol;
	}
	alias sockaddr SOCKADDR;

	enum SOMAXCONN = 0x7fffffff;
	auto SOMAXCONN_HINT(int b) { return -b; }

	enum _SS_MAXSIZE = 128;           // Maximum size
	enum _SS_ALIGNSIZE = long.sizeof; // Desired alignment

	enum _SS_PAD1SIZE = _SS_ALIGNSIZE - ushort.sizeof;
	enum _SS_PAD2SIZE = _SS_MAXSIZE - (ushort.sizeof + _SS_PAD1SIZE + _SS_ALIGNSIZE);

	struct SOCKADDR_STORAGE {
		ushort ss_family;
		byte[_SS_PAD1SIZE] __ss_pad1;
		long __ss_align;
		byte[_SS_PAD2SIZE] __ss_pad2;
	}
	alias SOCKADDR_STORAGE* PSOCKADDR_STORAGE;
	alias SOCKADDR_STORAGE sockaddr_storage;

	alias void function(DWORD, DWORD, WSAOVERLAPPEDX*, DWORD) LPWSAOVERLAPPED_COMPLETION_ROUTINEX;
	alias void function(DWORD, DWORD, WSAOVERLAPPEDX*) LPLOOKUPSERVICE_COMPLETION_ROUTINE;
	alias void* LPCONDITIONPROC;
	alias void* LPTRANSMIT_FILE_BUFFERS;

	alias BOOL function(SOCKET sListenSocket,
	                    SOCKET sAcceptSocket,
	                    void* lpOutputBuffer,
	                    DWORD dwReceiveDataLength,
	                    DWORD dwLocalAddressLength,
	                    DWORD dwRemoteAddressLength,
	                    DWORD* lpdwBytesReceived,
	                    OVERLAPPED* lpOverlapped) LPFN_ACCEPTEX;
	auto WSAID_ACCEPTEX = GUID(0xb5367df1, 0xcbac, 0x11cf, [ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 ]);

	alias void function(void* lpOutputBuffer,
	                    DWORD dwReceiveDataLength,
	                    DWORD dwLocalAddressLength,
	                    DWORD dwRemoteAddressLength,
	                    sockaddr** LocalSockaddr,
	                    int* LocalSockaddrLength,
	                    sockaddr** RemoteSockaddr,
	                    int* RemoteSockaddrLength) LPFN_GETACCEPTEXSOCKADDRS;
	auto WSAID_GETACCEPTEXSOCKADDRS = GUID(0xb5367df2, 0xcbac, 0x11cf, [ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 ]);

	alias BOOL function(SOCKET s, sockaddr* name, int namelen, void* lpSendBuffer, DWORD dwSendDataLength, DWORD* lpdwBytesSent, OVERLAPPED* lpOverlapped) LPFN_CONNECTEX;
	auto WSAID_CONNECTEX = GUID(0x25a207b9, 0xddf3, 0x4660, [ 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e ]);

	alias BOOL function(SOCKET s, OVERLAPPED* lpOverlapped, DWORD  dwFlags, DWORD  dwReserved) LPFN_DISCONNECTEX;
	auto WSAID_DISCONNECTEX = GUID(0x7fda2e11, 0x8630, 0x436f, [ 0xa0, 0x31, 0xf5, 0x36, 0xa6, 0xee, 0xc1, 0x57 ]);

	int WSAIoctl(SOCKET s, DWORD dwIoControlCode, void* lpvInBuffer, DWORD cbInBuffer, void* lpvOutBuffer, DWORD cbOutBuffer, DWORD* lpcbBytesReturned, WSAOVERLAPPEDX* lpOverlapped, LPWSAOVERLAPPED_COMPLETION_ROUTINEX lpCompletionRoutine);

	enum IOCPARM_MASK = 0x7f;
	enum uint IOC_VOID         = 0x20000000;
	enum uint IOC_OUT          = 0x40000000;
	enum uint IOC_IN           = 0x80000000;
	enum uint IOC_INOUT        = (IOC_IN|IOC_OUT);

	enum uint IOC_UNIX         = 0x00000000;
	enum uint IOC_WS2          = 0x08000000;
	enum uint IOC_PROTOCOL     = 0x10000000;
	enum uint IOC_VENDOR       = 0x18000000;

	auto _WSAIO(uint x,uint y)      { return (IOC_VOID|(x)|(y)); }
	auto _WSAIOR(uint x,uint y)     { return (IOC_OUT|(x)|(y)); }
	auto _WSAIOW(uint x,uint y)     { return (IOC_IN|(x)|(y)); }
	auto _WSAIORW(uint x,uint y)    { return (IOC_INOUT|(x)|(y)); }

	enum SIO_GET_EXTENSION_FUNCTION_POINTER = _WSAIORW(IOC_WS2,6);

	LPFN_ACCEPTEX AcceptEx;
	LPFN_GETACCEPTEXSOCKADDRS GetAcceptExSockaddrs;
	LPFN_CONNECTEX ConnectEx;
	LPFN_DISCONNECTEX DisconnectEx;

	enum SO_UPDATE_ACCEPT_CONTEXT    = 0x700B;
	enum SO_UPDATE_CONNECT_CONTEXT   = 0x7010;

	bool CancelIo(HANDLE hFile);
	bool CancelIOEx(HANDLE hFile, OVERLAPPED* lpOverlapped);

	SOCKET WSAAccept(SOCKET s, sockaddr *addr, INT* addrlen, LPCONDITIONPROC lpfnCondition, DWORD_PTR dwCallbackData);
	int WSAAsyncSelect(SOCKET s, HWND hWnd, uint wMsg, sizediff_t lEvent);
	SOCKET WSASocketW(int af, int type, int protocol, WSAPROTOCOL_INFOW *lpProtocolInfo, uint g, DWORD dwFlags);
	int WSARecv(SOCKET s, WSABUF* lpBuffers, DWORD dwBufferCount, DWORD* lpNumberOfBytesRecvd, DWORD* lpFlags, in WSAOVERLAPPEDX* lpOverlapped, LPWSAOVERLAPPED_COMPLETION_ROUTINEX lpCompletionRoutine);
	int WSASend(SOCKET s, in WSABUF* lpBuffers, DWORD dwBufferCount, DWORD* lpNumberOfBytesSent, DWORD dwFlags, in WSAOVERLAPPEDX* lpOverlapped, LPWSAOVERLAPPED_COMPLETION_ROUTINEX lpCompletionRoutine);
	int WSARecvFrom(SOCKET s, WSABUF* lpBuffers, DWORD dwBufferCount, DWORD* lpNumberOfBytesRecvd, DWORD* lpFlags, sockaddr* lpFrom, INT* lpFromlen, in WSAOVERLAPPEDX* lpOverlapped, LPWSAOVERLAPPED_COMPLETION_ROUTINEX lpCompletionRoutine);
	int WSASendTo(SOCKET s, in WSABUF* lpBuffers, DWORD dwBufferCount, DWORD* lpNumberOfBytesSent, DWORD dwFlags, sockaddr* lpTo, int iToLen, in WSAOVERLAPPEDX* lpOverlapped, LPWSAOVERLAPPED_COMPLETION_ROUTINEX lpCompletionRoutine);
	int WSASendDisconnect(SOCKET s, WSABUF* lpOutboundDisconnectData);
	INT WSAStringToAddressA(in LPTSTR AddressString, INT AddressFamily, in WSAPROTOCOL_INFO* lpProtocolInfo, SOCKADDR* lpAddress, INT* lpAddressLength);
	INT WSAStringToAddressW(in LPWSTR AddressString, INT AddressFamily, in WSAPROTOCOL_INFOW* lpProtocolInfo, SOCKADDR* lpAddress, INT* lpAddressLength);
	INT WSAAddressToStringW(in SOCKADDR* lpsaAddress, DWORD dwAddressLength, in WSAPROTOCOL_INFO* lpProtocolInfo, LPWSTR lpszAddressString, DWORD* lpdwAddressStringLength);
	int GetAddrInfoExW(LPCWSTR pName, LPCWSTR pServiceName, DWORD dwNameSpace, GUID* lpNspId, const ADDRINFOEXW *pHints, ADDRINFOEXW **ppResult, timeval *timeout, WSAOVERLAPPEDX* lpOverlapped, LPLOOKUPSERVICE_COMPLETION_ROUTINE lpCompletionRoutine, HANDLE* lpNameHandle);
	int GetAddrInfoW(LPCWSTR pName, LPCWSTR pServiceName, const ADDRINFOW *pHints, ADDRINFOW **ppResult);
	int getaddrinfo(LPCSTR pName, LPCSTR pServiceName, const ADDRINFOA *pHints, ADDRINFOA **ppResult);
	void FreeAddrInfoW(ADDRINFOW* pAddrInfo);
	void FreeAddrInfoExW(ADDRINFOEXW* pAddrInfo);
	void freeaddrinfo(ADDRINFOA* ai);
	BOOL TransmitFile(SOCKET hSocket, HANDLE hFile, DWORD nNumberOfBytesToWrite, DWORD nNumberOfBytesPerSend, OVERLAPPED* lpOverlapped, LPTRANSMIT_FILE_BUFFERS lpTransmitBuffers, DWORD dwFlags);

	enum WM_USER = 0x0400;

	enum {
		QS_ALLPOSTMESSAGE = 0x0100,
		QS_HOTKEY = 0x0080,
		QS_KEY = 0x0001,
		QS_MOUSEBUTTON = 0x0004,
		QS_MOUSEMOVE = 0x0002,
		QS_PAINT = 0x0020,
		QS_POSTMESSAGE = 0x0008,
		QS_RAWINPUT = 0x0400,
		QS_SENDMESSAGE = 0x0040,
		QS_TIMER = 0x0010,

		QS_MOUSE = (QS_MOUSEMOVE | QS_MOUSEBUTTON),
		QS_INPUT = (QS_MOUSE | QS_KEY | QS_RAWINPUT),
		QS_ALLEVENTS = (QS_INPUT | QS_POSTMESSAGE | QS_TIMER | QS_PAINT | QS_HOTKEY),
		QS_ALLINPUT = (QS_INPUT | QS_POSTMESSAGE | QS_TIMER | QS_PAINT | QS_HOTKEY | QS_SENDMESSAGE),
	};

	enum {
		MWMO_ALERTABLE = 0x0002,
		MWMO_INPUTAVAILABLE = 0x0004,
		MWMO_WAITALL = 0x0001,
	};
}
