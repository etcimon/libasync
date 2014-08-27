[![Build Status](https://travis-ci.org/etcimon/event.d.png)](https://travis-ci.org/etcimon/event.d)

About
-----

The event.d asynchroneous library (beta) is written completely in D, features a cross-platform event loop and enhanced connectivity and concurrency facilities for extremely lightweight asynchroneous tasks. It embeds naturally to D projects (version > 2.066.0), compiles statically with your project and has an open source license (MIT).

### Features

The following capabilities are now being tested and should not be used in any circumstance in a production environment.

- **Asynchroneous TCP connection** - handles multiple requests at a time in each individual thread

- **Asynchroneous TCP listener** - delivers a new connection to the delegate of your choice

- **UDP connection** - receives or sends packets from/to multiple peers

- **Timer** - sets a periodic or one-shot timer with high-precision (μs) to call a select delegate

- **Signal** - Wakes up the event loop in a foreign thread and passes a message to its delegate

- **Notifier** - Thread-local and lock-less adaptation of **Signal** which queues a message intended for a local delegate

- **Multi-threading** support - EventLoop can be launched and run from an unlimited number of threads!

(*) _Tested on Mac, Linux, Windows and FreeBSD_ - Platforms used were Mac OS X (10.8), Linux (Fedora 20) and Windows (8.1), although it should be compatible to 99% of Desktop OS users.

### Limitations

Some or all of these limitations are possibly being implemented currently and may be available in a future release.

- **Native Delegates** - Delegates must be implemented at a higher level, a choice made in favor of manual memory management friendliness
- **DNS resolver** - Currently only a thread-blocking DNS resolver is offered
- **File Watcher** - No file watcher is currently implemented
- **Async File I/O** - 50% completed
- **Signal** - An upper limit of 32 `AsyncSignal` instances can be `run()`ing per process on Linux
- **Futures and Promises** - Call chaining is not supported yet
- **Manual error management** - The entire library is `nothrow` and error management must be built on top of it.

Installation Instructions
-------------------------

- Download and install DMD 2.066.0+ from [dlang.org](http://dlang.org/download.html)
- Download and install dub 0.9.22-rc.2+ from [code.dlang.org](http://code.dlang.org/download)
- Use Git to clone this repository
- Run `dub test` to test the library on your operating system (submit any issue with a log report by uncommenting `enum LOG = true` in `types.d`)
- Add the library to your project by including it in the dependencies, using `import event.d`

Tutorial
--------

Only 2 examples are available at the moment, they are located in `examples/tcp_listener` and `examples/tcp_client`. They must be tested by starting the server before the client.