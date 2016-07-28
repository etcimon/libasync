
import core.time;

import std.stdio;
import std.socket;
import std.conv;
import std.format;
import std.file;
import std.exception;

import libasync;

int main(string[] args)
{
	if (args.length != 3) {
		stderr.writeln("sender: Usage: sender host port");
		return 1;
	}

	Address remote = void;
	try remote = new Internet6Address(args[1], args[2].to!ushort);
	catch (Exception e) {
		stderr.writeln("sender: ", e.msg);
		return 1;
	}

	auto running = true;

	auto eventLoop = getThreadEventLoop();

	auto client = new AsyncSocket(eventLoop, AddressFamily.INET6, SocketType.STREAM);

	void delegate() send = void;
	send = {
		client.send(cast(ubyte[]) "Hello, world!\n", send);
	};

	client.onConnect = { send(); };

	client.onClose = { running = false; };

	client.onError = {
		stderr.writeln("sender: ", client.error).collectException();
		running = false;
	};

	if(!client.run()) {
		stderr.writeln("sender: ", client.error);
		return 1;
	}

	if (!client.connect(remote.name, remote.nameLen)) {
		stderr.writeln("sender: ", client.error);
		return 1;
	}

	while (running) eventLoop.loop(-1.seconds);
	return 0;
}