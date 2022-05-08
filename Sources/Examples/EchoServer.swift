// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation
import WebSockets

// A simple WebSocket echo server that accepts WebSocket connections and echoes back any text or binary messages
// it receives from clients. Incoming message size is limited to 1 megabyte. If no message is received from a client
// for 30 seconds, the client is disconnected.
//
// The server also handles a couple of ordinary HTTP GET requests:
//   * "/stats" returns a response that includes information about the clients that are currently connected.
//   * "/shutdown/:key" shuts down the echo server using the key printed when the server is started.
//
actor EchoServer {
  let shutdownKey = UInt64.random(in: 1...UInt64.max)
  let server: WebSocketServer
  var nextConnectionId: UInt64 = 1
  var connections: [EchoConnection] = []

  init(on port: UInt16) {
    server = WebSocketServer(on: port)
  }

  func run() async throws {
    for try await event in server {
      switch event {
        case .ready:
          print("* Server is ready. To shutdown: http://localhost:\(server.port)/shutdown/\(shutdownKey)")
        case .networkUnavailable:
          print("* Server reports network unavailable")
        case .request(let request):
          await handleRequest(request)
      }
    }
  }

  // Performs an orderly shutdown of the server, sends a close frame to every connected websocket, and waits until
  // each websocket has responded with a close frame (or reached the closing handshake timeout).
  func stop() async {
    // First we stop the server so that no new connections can be established.
    await server.stop()
    // Then we close any connected websockets (in parallel). The loop is necessary in case there were still
    // requests available in the `WebSocketServer` event queue when the shutdown was initiated.
    while !connections.isEmpty {
      await withTaskGroup(of: Void.self) { group in
        for connection in connections {
          group.addTask {
            await connection.stop(with: .goingAway, reason: "The server is shutting down")
          }
        }
      }
    }
  }

  private func handleRequest(_ request: WebSocketServer.Request) async {
    if request.upgradeRequested {
      var options = WebSocket.Options()
      options.maximumIncomingMessageSize = 1024 * 1024
      guard let socket = await request.upgrade(options: options) else {
        return
      }
      let id = nextConnectionId
      nextConnectionId += 1
      let connection = EchoConnection(with: socket, id: id, endpoint: request.clientEndpoint, server: self)
      connections.append(connection)
      await connection.start()
      print("* Created connection #\(id) for endpoint \(request.clientEndpoint)")
      return
    }

    guard request.method == .get else {
      await request.respond(with: .badRequest, plainText: "This server supports only GET requests")
      return
    }

    if request.target == "/stats" {
      var output = "Currently connected clients:\n"
      if connections.isEmpty {
        output += "  (none)\n"
      } else {
        for connection in connections {
          output += "  #\(connection.id) from \(connection.endpoint)\n"
        }
      }
      await request.respond(with: .ok, plainText: output)
      return
    }

    if request.target == "/shutdown/\(shutdownKey)" {
      print("* Shutting down with valid key")
      await request.respond(with: .ok, plainText: "Shutting down")
      await stop()
      return
    }

    await request.respond(with: .notFound, plainText: "The requested resource does not exist")
  }

  func connectionClosed(_ connection: EchoConnection) {
    if let index = connections.firstIndex(where: { $0 === connection }) {
      print("* Connection #\(connection.id) was closed")
      connections.remove(at: index)
    }
  }
}

actor EchoConnection {
  let socket: WebSocket
  let id: UInt64
  let endpoint: String
  weak var server: EchoServer?
  var mainTask: Task<Void, Never>?
  var watchdogTask: Task<Void, Never>?

  init(with socket: WebSocket, id: UInt64, endpoint: String, server: EchoServer) {
    self.socket = socket
    self.id = id
    self.endpoint = endpoint
    self.server = server
  }

  func start() {
    guard mainTask == nil else {
      return
    }
    mainTask = Task {
      await run()
    }
  }

  func stop(with code: WebSocket.CloseCode = .goingAway, reason: String = "") async {
    await socket.close(with: code, reason: reason)
    await mainTask?.value
  }

  private func run() async {
    resetWatchdog()
    await socket.send(text: "Welcome to the echo server.")
    do {
      for try await event in socket {
        switch event {
          case .text(let str):
            await socket.send(text: str)
            resetWatchdog()
          case .binary(let data):
            await socket.send(data: data)
            resetWatchdog()
          default:
            break
        }
      }
      watchdogTask?.cancel()
      watchdogTask = nil
      await server?.connectionClosed(self)
    } catch {
      // Server sockets do not throw.
    }
  }

  private func resetWatchdog() {
    watchdogTask?.cancel()
    watchdogTask = Task {
      if (try? await Task.sleep(nanoseconds: 30_000_000_000)) != nil {
        await socket.close(with: .normalClosure, reason: "Closing due to inactivity")
      }
    }
  }
}
