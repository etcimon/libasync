
enum NETLINK_USER = 31;
enum MAX_PAYLOAD = 1024;

sockaddr_nl src_addr, dest_addr;
nlmsghdr* nlh;

int main(string[] args)
{
	auto eventLoop = getThreadEventLoop();

	auto socket = new AsyncSocket(eventLoop, AF_NETLINK, SOCK_RAW, NETLINK_USER);

	socket.onError = {
		stderr.writeln("netlink: ", socket.error).collectException();
		g_running = false;
		g_status = 1;
	};

	if(!socket.run()) {
		stderr.writeln("netlink: ", socket.error);
		return 1;
	}

	src_addr.nl_family = AF_NETLINK;
	src_addr.nl_pid = thisProcessID();

	if (!socket.bind(cast(sockaddr*) &src_addr, cast(socklen_t) src_addr.sizeof)) {
		stderr.writeln("netlink: ", socket.error);
		return 1;
	}

	dest_addr.nl_family = AF_NETLINK;
	dest_addr.nl_pid = 0;    // For Linux kernel
	dest_addr.nl_groups = 0; // Unicast

	nlh = cast(nlmsghdr*) GC.calloc(NLMSG_SPACE(MAX_PAYLOAD));
	nlh.nlmsg_len = NLMSG_SPACE(MAX_PAYLOAD);
	nlh.nlmsg_pid = thisProcessID();
	nlh.nlmsg_flags = 0;

	copy("Hello", cast(char[]) NLMSG_DATA(nlh)[0..MAX_PAYLOAD]);

	auto message = NetworkMessage((cast(ubyte*) nlh)[0..nlh.nlmsg_len]);
	message.name = cast(sockaddr*) &dest_addr;
	message.nameLength = dest_addr.sizeof;

	socket.sendMessage(message, {
		socket.receiveMessage(message, (data) {
			stdout.writeln((cast(char*) NLMSG_DATA(cast(nlmsghdr*) data)).fromStringz).collectException;
		});
	});

	foreach (i; 1..10) {
		if (!g_running) break;
		else eventLoop.loop(10.msecs);
	}
	return g_status;
}

int g_status;
bool g_running = true;

import core.time;
import core.sys.posix.sys.types : pid_t;
import core.memory;

import std.stdio : stdout, stderr;
import std.exception : collectException;
import std.process : thisProcessID;
import std.string : fromStringz;
import std.algorithm.mutation : copy;

import libasync;
import libasync.internals.socket_compat : sa_family_t, sockaddr, socklen_t;

enum AF_NETLINK = 16;

enum NLMSG_ALIGNTO = cast(uint) 4;
auto NLMSG_ALIGN(uint len) { return (len + NLMSG_ALIGNTO - 1) & ~(NLMSG_ALIGNTO - 1); }
enum NLMSG_HDRLEN = cast(uint) NLMSG_ALIGN(nlmsghdr.sizeof);
auto NLMSG_LENGTH(uint len) { return len + NLMSG_HDRLEN; }
auto NLMSG_SPACE(uint len) { return NLMSG_ALIGN(NLMSG_LENGTH(len)); }
auto NLMSG_DATA(nlmsghdr* nlh) { return cast(void*) (cast(ubyte*) nlh) + NLMSG_LENGTH(0); }
auto NLMSG_NEXT(nlmsghdr* nlh, ref uint len) {
	len -= NLMSG_ALIGN(nlh.nlmsg_len);
	return cast(nlmsghdr*) ((cast(ubyte*) nlh) + NLMSG_ALIGN(nlh.nlmsg_len));
}
auto NLMSG_OK(nlmsghdr* nlh, uint len)
{
	return len >= nlmsghdr.sizeof &&
		nlh.nlmsg_len >= nlmsghdr.sizeof &&
		nlh.nlmsg_len <= len;
}
auto NLMSG_PAYLOAD(nlmsghdr* nlh, uint len)
{ return nlh.nlmsg_len - NLMSG_SPACE(len); }

struct nlmsghdr {
	uint nlmsg_len;      /// Length of message including header
	ushort nlmsg_type;   /// Type of message content
	ushort nlmsg_flags;  /// Additional flags
	uint nlmsg_seq;      /// Sequence number
	uint nlmsg_pid;      /// Sender port ID
}

struct nlmsgerr {
	int error;        /// Negative errno or 0 for acknowledgements
	nlmsghdr msg;     /// Message header that caused the error
}

struct sockaddr_nl {
	sa_family_t nl_family;  /// AF_NETLINK
	ushort nl_pad;          /// Zero
	pid_t nl_pid;           /// Port ID
	uint nl_groups;       /// Multicast groups mask
};