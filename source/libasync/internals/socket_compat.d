/**
 * D header file for POSIX.
 *
 * Copyright: Copyright Sean Kelly 2005 - 2009.
 * License:   <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
 * Authors:   Sean Kelly, Alex Rønne Petersen
 * Standards: The Open Group Base Specifications Issue 6, IEEE Std 1003.1, 2004 Edition
 */

/*          Copyright Sean Kelly 2005 - 2009.
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module libasync.internals.socket_compat;

version (Windows)
{
	public import libasync.internals.win32 :
		sockaddr, sockaddr_storage, sockaddr_in, sockaddr_in6,
		AF_UNSPEC, AF_INET, AF_INET6,
		socklen_t,
		getsockname, getpeername,
		SOL_SOCKET, SO_TYPE, SO_ERROR, SO_REUSEADDR,
		getsockopt, setsockopt,
		bind, connect, listen, SOMAXCONN,
		SOCK_STREAM, SOCK_SEQPACKET, SOCK_DGRAM, SOCK_RAW, SOCK_RDM;
} else:

public import core.sys.posix.sys.un;

version(OSX) {
	public import core.sys.posix.arpa.inet;
	public import core.sys.posix.netdb;
	public import core.sys.posix.netinet.tcp;
	public import core.sys.posix.netinet.in_;
	public import core.sys.posix.sys.select;
	public import core.sys.posix.sys.socket;
	private import core.sys.posix.config;
	public import core.sys.posix.sys.types; // for ssize_t, size_t
	public import core.sys.posix.sys.uio;   // for iovec


	enum: int
	{
		TCP_MAX_SACK = 3,
		TCP_MSS = 512,
		TCP_MINMSS = 216,
		TCP_MINMSSOVERLOAD = 1000,
		TCP_MAXWIN = 65535L,
		TCP_MAX_WINSHIFT = 14,
		TCP_MAXBURST = 4,
		TCP_MAXHLEN = 60,
		TCP_MAXOLEN = 40,
		TCP_NODELAY = 1,
		TCP_MAXSEG = 2,
		TCP_NOPUSH = 4,
		TCP_NOOPT = 8,
		TCP_KEEPALIVE = 16,
		TCP_QUICKACK = -1,
		TCP_KEEPCNT = -1,
		TCP_KEEPINTVL = -1,
		TCP_KEEPIDLE = -1,
		TCP_CONGESTION = -1,
		TCP_CORK = -1,
		TCP_DEFER_ACCEPT = -1
	}
}

else version (linux) {
	private import core.sys.posix.config;
	public import core.sys.posix.sys.types; // for ssize_t, size_t
	public import core.sys.posix.sys.uio;   // for iovec
	public import core.sys.posix.arpa.inet;
	public import core.sys.posix.netdb;
	public import core.sys.posix.netinet.tcp;
	public import core.sys.posix.netinet.in_;
	public import core.sys.posix.sys.select;
	public import core.sys.posix.sys.socket;

	enum: int
	{
		TCP_MAXSEG = 2,
		TCP_CORK = 3,
		TCP_KEEPIDLE = 4,
		TCP_KEEPINTVL = 5,
		TCP_KEEPCNT = 6,
		TCP_SYNCNT = 7,
		TCP_LINGER2 = 8,
		TCP_DEFER_ACCEPT = 9,
		TCP_WINDOW_CLAMP = 10,
		TCP_INFO = 11,
		TCP_QUICKACK = 12,
		TCP_CONGESTION = 13,
		TCP_MD5SIG = 14
	}
}
extern (C) nothrow @nogc:

//
// Required
//
/*
socklen_t
sa_family_t

struct sockaddr
{
    sa_family_t sa_family;
    char        sa_data[];
}

struct sockaddr_storage
{
    sa_family_t ss_family;
}

struct msghdr
{
    void*         msg_name;
    socklen_t     msg_namelen;
    struct iovec* msg_iov;
    int           msg_iovlen;
    void*         msg_control;
    socklen_t     msg_controllen;
    int           msg_flags;
}

struct iovec {} // from core.sys.posix.sys.uio

struct cmsghdr
{
    socklen_t cmsg_len;
    int       cmsg_level;
    int       cmsg_type;
}

SCM_RIGHTS

CMSG_DATA(cmsg)
CMSG_NXTHDR(mhdr,cmsg)
CMSG_FIRSTHDR(mhdr)

struct linger
{
    int l_onoff;
    int l_linger;
}

SOCK_DGRAM
SOCK_SEQPACKET
SOCK_STREAM

SOL_SOCKET

SO_ACCEPTCONN
SO_BROADCAST
SO_DEBUG
SO_DONTROUTE
SO_ERROR
SO_KEEPALIVE
SO_LINGER
SO_OOBINLINE
SO_RCVBUF
SO_RCVLOWAT
SO_RCVTIMEO
SO_REUSEADDR
SO_SNDBUF
SO_SNDLOWAT
SO_SNDTIMEO
SO_TYPE

SOMAXCONN

MSG_CTRUNC
MSG_DONTROUTE
MSG_EOR
MSG_OOB
MSG_PEEK
MSG_TRUNC
MSG_WAITALL

AF_INET
AF_UNIX
AF_UNSPEC

SHUT_RD
SHUT_RDWR
SHUT_WR

int     accept(int, sockaddr*, socklen_t*);
int     accept4(int, sockaddr*, socklen_t*, int flags);
int     bind(int, in sockaddr*, socklen_t);
int     connect(int, in sockaddr*, socklen_t);
int     getpeername(int, sockaddr*, socklen_t*);
int     getsockname(int, sockaddr*, socklen_t*);
int     getsockopt(int, int, int, void*, socklen_t*);
int     listen(int, int);
ssize_t recv(int, void*, size_t, int);
ssize_t recvfrom(int, void*, size_t, int, sockaddr*, socklen_t*);
ssize_t recvmsg(int, msghdr*, int);
ssize_t send(int, in void*, size_t, int);
ssize_t sendmsg(int, in msghdr*, int);
ssize_t sendto(int, in void*, size_t, int, in sockaddr*, socklen_t);
int     setsockopt(int, int, int, in void*, socklen_t);
int     shutdown(int, int);
int     socket(int, int, int);
int     sockatmark(int);
int     socketpair(int, int, int, ref int[2]);
*/

version( linux )
{
	version (X86)
	{
		enum SO_REUSEPORT = 15;
	}
	else version (X86_64)
	{
		enum SO_REUSEPORT = 15;
	}
	else version (MIPS32)
	{
		enum SO_REUSEPORT = 0x0200;
	}
	else version (MIPS64)
	{
		enum SO_REUSEPORT = 0x0200;
	}
	else version (PPC)
	{
		enum SO_REUSEPORT = 15;
	}
	else version (PPC64)
	{
		enum SO_REUSEPORT = 15;
	}
	else version (ARM)
	{
		enum SO_REUSEPORT = 15;
	}
	else
		static assert(0, "unimplemented");

	int accept4(int, sockaddr*, socklen_t*, int flags);
}
else version( OSX )
{
	enum SO_REUSEPORT = 0x0200;

	int accept4(int, sockaddr*, socklen_t*, int flags);
}
else version( FreeBSD )
{
	enum SO_REUSEPORT = 0x0200;

	int accept4(int, sockaddr*, socklen_t*, int flags);
}
else version (Solaris)
{
	enum SO_REUSEPORT = 0x0200;

	int accept4(int, sockaddr*, socklen_t*, int flags);
}
else version( Android )
{
	version (X86)
	{
		enum SO_REUSEPORT = 15;
	}
	else
	{
		static assert(false, "Architecture not supported.");
	}

	// constants needed for std.socket
	enum IPPROTO_IGMP = 2;
	enum IPPROTO_PUP  = 12;
	enum IPPROTO_IDP  = 22;
	enum INADDR_NONE  = 0xFFFFFFFF;

	int accept4(int, sockaddr*, socklen_t*, int flags);
}
else
{
	static assert(false, "Unsupported platform");
}
