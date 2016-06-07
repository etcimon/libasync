[![Build Status](https://travis-ci.org/etcimon/libasync.png)](https://travis-ci.org/etcimon/libasync)
﻿[![Build status](https://ci.appveyor.com/api/projects/status/ryvd5tlgjyqmjpsm?svg=true)](https://ci.appveyor.com/project/etcimon/libasync)

About
-----

The libasync asynchronous library is written completely in D, features a cross-platform event loop and enhanced connectivity and concurrency facilities for extremely lightweight asynchronous tasks. It embeds naturally to D projects (DMD >= 2.067.0, LDC >= 0.15.1), compiles statically with your project and has an open source license (MIT).

A fully functional, tested vibe.d driver is available in [the latest version of vibe.d](https://github.com/rejectedsoftware/vibe.d/), you can enable it by appending `"subConfigurations": { "vibe-d": "libasync"}` in your project's dub.json configuration file.

### Features

The following capabilities are now being tested and should not be used in any circumstance in a production environment.

(*) _Unit tests confirmed on Mac, Linux, Windows_ - Platforms used were Mac OS X (10.8, 10.9), Linux (Fedora 20+) and Windows 32/64 bit, although it should be compatible to 99% of Desktop OS users.

(*) _Compiles with DMD & LDC_ (DMD 2.067.0, 2.067.1, LDC 0.15.1)

- **Multi-threading** support - EventLoop can be launched and run from an unlimited number of threads!

- **Asynchronous TCP connection** - handles multiple requests at a time in each individual thread

- **Buffered TCP connection** - Allows callbacks to be attached to a byte sized future

- **Asynchronous TCP listener** - delivers a new connection to the delegate of your choice

- **File Operations** - executes file read/write/append commands in a thread pool, notifies of completion in a handler

- **DNS resolver** - runs blocking DNS resolve operations in a thread pool, savings are the duration of a ping.

- **File/Folder Watcher** - watches directories for file changes (CREATE, DELETE, MODIFY, RENAME/MOVE)

- **UDP connection** - receives or sends packets from/to multiple peers

- **Timer** - sets a periodic or one-shot/periodic timer with high-precision (μs) to call a select delegate

- **Signal** - Wakes up the event loop in a foreign thread and passes a message to its delegate

- **Notifier** - Thread-local and lock-less adaptation of **Signal** which queues a message intended for a local delegate

### Limitations

Some or all of these limitations are possibly being implemented currently and may be available in a future release.

- **One EventLoop per thread** - There is a hard limit of one event loop per thread
- **Manual error management** - The entire library is `nothrow` and error management must be built on top of it.
- **No embedded HTTP or TLS handlers** - The support fort HTTP, TLS (and other protocols) is only available through vibe.d with Tasks as of yet.

Installation Instructions
-------------------------

- Download and install DMD 2.067.0+ from [dlang.org](http://dlang.org/download.html)
- Download and install dub 0.9.22+ from [code.dlang.org](http://code.dlang.org/download)
- Use Git to clone this repository
- Run `dub test` to test the library on your operating system (submit any issue with a log report by uncommenting `enum LOG = true` in `types.d`)
- Add the library to your project by including it in the dependencies, using `import libasync`
- The recommended editor is MonoDevelop with [Mono-D](http://wiki.dlang.org/Mono-D) due to its Mixin Template resolver (must be enabled manually), with auto-completion and comment-resolved summary tooltips.
- On another note, you can also try the vibe.d libasync built-in driver by adding `"subConfigurations": { "vibe-d": "libasync" }` to your vibe.d dub.json.

Tutorial
--------

There are 4 examples available at the moment, they are located in `examples/`. They must be tested by starting the server before the client.

All other usage examples are available in `source/libasync/test.d`. 

Documentation has been written throughout the code.
