import libasync;

import std.functional : toDelegate;
import std.stdio      : writeln;

void main()
{
    auto evl      = new EventLoop;
    auto listener = new TCPListener(evl);
    listener.connect(
        "localhost",
        8081,
        (conn)
        {
            conn.read(12, toDelegate(&onRead));
        },
        (conn)
        {
            writeln("Connection closed");
        },
        (conn)
        {
            writeln("Error during TCP Event");
        });

    while (true)
        evl.loop();
    /*destroyAsyncThreads();*/
}

alias Buffered = BufferedTCPConnection!4092;

void onRead(Buffered conn, in ubyte[] msg)
{
    auto res = cast(string)msg;
    writeln("Received: ", res);

    auto buf = cast(ubyte[])("Some reply");
    conn.write(buf, buf.length, (conn2)
    {
        conn.read(12, toDelegate(&onRead));
    });
}

class TCPListener
{
    private
    {
        AsyncTCPListener listener;

        Buffered.OnEvent onConnectCb;
        Buffered.OnEvent onCloseCb;
        Buffered.OnEvent onErrorCb;
    }

    this(scope EventLoop evl)
    {
        listener = new AsyncTCPListener(evl);
    }

    void connect(
        in string           host,
        in size_t           port,
        in Buffered.OnEvent onConnectCb,
        in Buffered.OnEvent onCloseCb,
        in Buffered.OnEvent onErrorCb)
    {
        this.onConnectCb = onConnectCb;
        this.onCloseCb   = onCloseCb;
        this.onErrorCb   = onErrorCb;

        auto ok = listener.host(host, port).run((AsyncTCPConnection conn)
        {
            auto bufConn = new Buffered(
                conn, onConnectCb, onCloseCb, onErrorCb);
            return &bufConn.handle;
        });

        if (ok)
            writeln("Listening to ", listener.local);
    }
}
