import libasync;

import std.stdio : writeln;

void main()
{
    auto evl       = new EventLoop;
    auto tcpClient = new TCPClient(evl, "localhost", 8081);

    while (true)
    {
        tcpClient.write(cast(ubyte[])("Some message"), (conn)
        {
            conn.read(10, (conn, msg)
            {
                auto res = cast(string)msg;
                writeln("Received: ", res);
            });

        });
        evl.loop();
    }
    /*destroyAsyncThreads();*/
}

class TCPClient
{
    alias Buffered = BufferedTCPConnection!4092;

    private Buffered conn;

    this(EventLoop evl, string host, size_t port)
    {
        this.conn = new Buffered(evl);

        if (!conn.host(host, port).run(&conn.handle))
            writeln(conn.status);
    }

    void read(in size_t len, in Buffered.OnRead onReadCb)
    {
        conn.read(len, onReadCb);
    }

    void write(in ubyte[] msg, in Buffered.OnEvent cb)
    {
        conn.write(msg, msg.length, cb);
    }
}
