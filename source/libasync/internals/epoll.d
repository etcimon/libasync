/**
 * D header file to interface with the Linux epoll API (http://man7.org/linux/man-pages/man7/epoll.7.html).
 * Available since Linux 2.6
 *
 * Copyright: Copyright Adil Baig 2012.
 * License : $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors  : Adil Baig (github.com/adilbaig)
 */
module libasync.internals.epoll;

public import core.sys.linux.epoll;

version (linux):

extern (C):
@system:
nothrow:

// Backport fix from druntime commit c94547af8d55e1490b51aac358171b761da6a657
static if (__VERSION__ < 2071)
{
	version (X86) immutable PackedEvent = true;
	else version (X86_64) immutable PackedEvent = true;
	else version (ARM) immutable PackedEvent = false;
	else version (AArch64) immutable PackedEvent = false;
	else version (PPC) immutable PackedEvent = false;
	else version (PPC64) immutable PackedEvent = false;
	else version (MIPS64) immutable PackedEvent = false;
	else version (SystemZ) immutable PackedEvent = false;
	else static assert(false, "Platform not supported");

	static if (PackedEvent)
	{
		align(1) struct epoll_event
		{
		align(1):
			uint events;
			epoll_data_t data;
		}
	}
	else
	{
		struct epoll_event
		{
			uint events;
			epoll_data_t data;
		}
	}

	int epoll_ctl (int epfd, int op, int fd, epoll_event *event);
	int epoll_wait (int epfd, epoll_event *events, int maxevents, int timeout);
}

enum EFD_NONBLOCK = 0x800;
enum EPOLL_CLOEXEC = 0x80000;

int eventfd (uint initval, int flags);

// Available as of druntime commit d4ef137ffd1a92e003b45d5a53958322d317271c
static if (__VERSION__ >= 2070)
{
	public import core.sys.linux.timerfd : timerfd_create, timerfd_settime;
}
else
{
	int timerfd_create (int clockid, int flags);
	int timerfd_settime (int fd, int flags, itimerspec* new_value, itimerspec* old_value);
}

import core.sys.posix.time : itimerspec;

import core.sys.posix.pthread : pthread_t;
import core.sys.posix.signal : sigval;
int pthread_sigqueue(pthread_t, int sig, in sigval);
