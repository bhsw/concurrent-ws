# concurrent-ws

An implementation of WebSockets ([RFC 6455](https://datatracker.ietf.org/doc/html/rfc6455)) for Swift 5.5 and above,
featuring an API based on Swift Concurrency (tasks and async/await).

**NOTE**: Swift Concurrency is still a relatively new technology. I personally haven't run into any issues with it, but
I know there have been rough spots, particularly in earlier releases. It appears that there may still be some churn
until Swift 6 is reached, so you may want to consider it an experimental technology for now. In any event, I'd recommend
targetting only the latest toolchain (Swift 5.6) and platforms (macOS 12.x or iOS 15.x).

[![Swift](https://github.com/bhsw/concurrent-ws/actions/workflows/swift.yml/badge.svg)](https://github.com/bhsw/concurrent-ws/actions/workflows/swift.yml)

## Features

* Supports both `ws` (unencrypted) and `wss` (TLS) URL schemes
* Includes client and server implementations
* Supports the `permessage-deflate` WebSocket compression extension
* Many tunable options, including:
  * Maximum incoming message length
  * HTTP redirect behavior
  * Custom HTTP headers
  * Timeouts for the opening and closing handshakes
  * Automatic ping response
  * Thresholds to trigger or inhibit compression for text and binary messages
* Extensive statistics for data sent and received by the WebSocket
* A fully documented public API
* 100% Swift using actors to protect mutable state
* Uses the platform's `Network` framework for communication (TCP/IP and TLS layers only)
* No third-party dependencies
* MIT License


## Client Usage

Let's look at a basic client example:

```swift
import WebSockets

let socket = WebSocket(url: URL("wss://echo.websocket.events")!)
await socket.send(text: "Hello, world")
do {
  for try await event in socket {
    switch event {
      case .open(let handshakeResult):
        print("Successfully opened the WebSocket: \(handshakeResult)")
      case .text(let str):
        print("Received text: \(str)")
      case .close(code: let code, reason: _, wasClean: _):
        print("Closed with code: \(code)")
      default:
        print("Miscellaneous event: \(event)")
    }
  }
} catch {
  print("An error occurred connecting to the remote endpoint: \(error)")
}
```

A `WebSocket` actor is an `AsyncSequence` containing events that you iterate using
a `for try await` loop. Events include notifications that the connection was
established successfully, that a message was received from the remote endpoint, or
that a disconnect occurred. In fact, iterating over these events is what drives the
operation of the WebSocket. For this reason, you will need to spin up a separate
`Task` to service the events for each WebSocket managed by your application. While
handling events is restricted to a single task, the rest of the API can be called
from any task. For example, it is particularly common to call a WebSocket's `send`
or `close` functions in response to a user interface event.

After initializing a `WebSocket`, no connection attempt is actually made until you
either ask to send a message to the remote endpoint or start consuming events.
An error will be thrown if a connection cannot be established. Otherwise, the first
event produced will be an `open` event, after which the WebSocket is guaranteed not
to throw any errors; if an error occurs after the WebSocket reaches the `open`
state, it is reported as `close` event with an appropriate `CloseCode`.

The event stream always ends with a `close` event. Once that event is consumed, the
event processing loop will complete.


## Server Usage

The following is a simple WebSocket server that accepts connections on port `8080`
and echoes back any text message received from a client:

```swift
let server = WebSocketServer(on: 8080)
for try await event in server {
  switch event {
    case .request(let request):
      guard let socket = await request.upgrade() else {
        break
      }
      Task {
        await socket.send(text: "Welcome to the echo server.")
        for try await event in socket {
          switch event {
            case .text(let string):
              await socket.send(text: string)
            default:
              break
          }        
        }
      }
    default:
      break
  }
}
```

The `WebSocketServer` actor works similarly becuase it is also an `AsyncSequence`.
The primary event produced by the server is a `request` event, which includes a
reference to a `WebSocketServer.Request` object that describes an HTTP 1.1
request from a client. Based on the information conveyed by the request, your
server application can send a normal HTTP response or attempt to upgrade the
connection to a WebSocket. The example above requires every request to be
an upgrade request. Anything else will receive a `400 Bad Request` response.

A successful upgrade returns a `WebSocket` actor that can then be used to
communicate with the client. WebSockets returned by the server are guaranteed
to never throw errors, because they are already in the `open` state by the
time they are made available to the application. Notice that communication with
each WebSocket is performed within its own `Task`. Without that, the server would
upgrade a single connection and then stop accepting further connections until
that first WebSocket was closed.

The `Sources/Examples` directory of the respository contains a much more
elaborate echo server.
