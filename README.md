# concurrent-websockets

This library provides an implementation of WebSockets for Swift 5.6 and above, featuring an API based on
Swift Concurrency (tasks and async/await). It strives to be fully compliant with
[RFC 6455](https://datatracker.ietf.org/doc/html/rfc6455), with exceptions only where warranted because of
restrictions that are irrelevant to non-browser clients.

Concurrent-websockets is written entirely in Swift and has no dependencies other than Foundation, Network.framework,
and CryptoKit.

## Features

* Thread-safe API 
* Supports both `ws` (unencrypted) and `wss` (TLS) URL schemes.
* A maximum length can be configured for incoming messages.
* HTTP redirects are handled by default but can be disabled if desired.
* Additional HTTP headers may be added to the opening handshake.
* Opening handshake errors include information from the HTTP response, including the HTTP status code, headers,
  and content.
* Tunable timeouts for the opening and closing handshakes.
