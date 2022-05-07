// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation
import WebSockets

@main
struct App {
  static func main() async {
    do {
//      try await testClient()
//      try await testSimpleClient()
      try await testServer()
    } catch {
      print("ERROR:", error)
    }
  }

  static func testClient() async throws {
//    let url = URL(string: "ws://europa.ocsoft.net:8080/testx")!
//    let url = URL(string: "ws://light.ocsoft.net/api/logs")!
//    let url = URL(string: "wss://m.ocsoft.com/api/logs")!
//    let url = URL(string: "wss://echo.websocket.events")!
    let url = URL(string: "wss://blob.ocsoft.com/redirect-test")!
//    let url = URL(string: "wss://github.com")!
    var options = WebSocket.Options()
    options.closingHandshakeTimeout = 3
    options.openingHandshakeTimeout = 1
    let sock = WebSocket(url: url, options: options)
    let t = Task {
      await sock.send(text: "{ \"op\": \"nope\" }")
      print("Sending ping:", await sock.ping(data: "Ping!".data(using: .utf8)!))
      try! await Task.sleep(nanoseconds: 10_000_000_000)
      await sock.close(with: .goingAway, reason: "Going away but this time using a message that is going to be too long to fit in the space provided and will therefore be truncated somewhere")
    }
    do {
      for try await event in sock {
        print("EVENT:", event)
      }
    } catch WebSocketError.unexpectedHTTPStatus(let result) {
      print("STATUS:", result.status)
      if let contentType = result.contentType {
        print("CONTENT-TYPE:", contentType)
        if contentType.mediaType.starts(with: "text/"), let content = result.content {
          print("CONTENT:", String(data: content, encoding: .utf8)!)
        }
      }
    } catch {
      print("ERROR: \(error)")
    }

    await t.value
  }

  static func testSimpleClient() async throws {
    let socket = WebSocket(url: URL(string: "wss://echo.websocket.events")!)
    do {
      for try await event in socket {
        switch event {
          case .open(_):
            print("Successfully opened the WebSocket")
            await socket.send(text: "Hello, world")
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
  }

  static func testServer() async throws {
    let server = EchoServer(on: 8080)
//    let timer = Task {
//      try await Task.sleep(nanoseconds: 15_000_000_000)
//      await server.stop()
//    }
    try await server.run()
//    try await timer.value
  }

  static func testDumbServer() async throws {
    let server = WebSocketServer(on: 8080)
    for try await event in server {
      switch event {
        case .ready:
          print("Ready to accept requests")
        case .request(let request):
          await request.respond(with: .ok, plainText: "You performed a \(request.method) on \(request.target)\n")
        case .networkUnavailable:
          print("The network is unavailable")
      }
    }
  }
}
