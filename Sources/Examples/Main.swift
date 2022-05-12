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

  static func testSimpleClient() async throws {
    let socket = WebSocket(url: URL(string: "wss://echo.websocket.events")!)
    Task {
      for index in 1...10 {
        print("Sending #\(index)")
        await socket.send(text: "Hello, world #\(index)")
      }
      print("Closing")
      await socket.close(with: .goingAway)
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    print("Entering event loop")
    do {
      for try await event in socket {
        switch event {
          case .open(_):
            print("Successfully opened the WebSocket")
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
