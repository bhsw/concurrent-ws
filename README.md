# concurrent-websockets

An implementation of WebSockets ([RFC 6455](https://datatracker.ietf.org/doc/html/rfc6455)) for Swift 5.6 and above,
featuring an API based on Swift Concurrency (tasks and async/await).

This library is written entirely in Swift and has no dependencies other than platform frameworks `Foundation`, `Network`,
and `CryptoKit`.

**IMPORTANT**: This software should be considered alpha-quality at this time. Tests are missing, and the API is subject
to change at any time.


## Features

* A fully documented public API.
* Supports both `ws` (unencrypted) and `wss` (TLS) URL schemes.
* Many tunable options, such as maximum incoming message length, HTTP redirect behavior, custom HTTP headers, and
  timeouts for the opening and closing handshakes.
* A simple HTTP 1.1 server with the ability to upgrade connections to WebSockets.

## Not Currently Supported

* WebSocket extensions, notably `permessage-deflate`.
