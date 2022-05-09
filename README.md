# concurrent-websockets

An implementation of WebSockets ([RFC 6455](https://datatracker.ietf.org/doc/html/rfc6455)) for Swift 5.5 and above,
featuring an API based on Swift Concurrency (tasks and async/await). The minimum supported platforms are macOS 10.15+
(Catalina) and iOS 15+.

**IMPORTANT**: This software should be considered alpha-quality at this time. Tests are still being added, and the API
is subject to change at any time.


## Features

* Supports both `ws` (unencrypted) and `wss` (TLS) URL schemes
* Many tunable options, including:
  * Maximum incoming message length
  * HTTP redirect behavior
  * Custom HTTP headers
  * Timeouts for the opening and closing handshakes
  * Automatic ping response
* A simple HTTP 1.1 server with the ability to upgrade connections to WebSockets
* A fully documented public API
* 100% Swift using actors to protect mutable state
* Uses the platform's `Network` framework for communication (TCP/IP and TLS layers only)
* No third-party dependencies
* MIT License


## Not Currently Supported

* WebSocket extensions, notably `permessage-deflate`.
