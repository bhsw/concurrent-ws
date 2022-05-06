// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation
import WebSockets

typealias ConnectionId = Int64

// A simple WebSocket echo server that accepts WebSocket connections and echoes back any text or binary messages
// it receives from clients. Incoming message size is limited to 1 megabyte. If no message is received from a client
// for 30 seconds, the client is disconnected.
//
// The server also handles ordinary HTTP GET requests to "/stats" and returns a response that includes the number
// of WebSocket clients currently connected.
//
actor Server {
  let server: WebSocketServer
  var nextConnectionId: ConnectionId = 1
  var connections: [ConnectionId: Connection] = [:]

  init(on port: UInt16) {
    server = WebSocketServer(on: port)
  }

  func run() async throws {
    for try await event in server {
      switch event {
        case .ready:
          print("* Server is ready")
        case .networkUnavailable:
          print("* Server reports network unavailable")
        case .client(let client):
          accept(client: client)
      }
    }
  }

  // Performs an orderly shutdown of the server, sends a close frame to every connected websocket, and waits until
  // each websocket has responded with a close frame (or reached the closing handshake timeout).
  func stop() async {
    // First we stop the server so that no new connections can be established.
    await server.stop()
    // Then we close any connected websockets (in parallel).
    await withTaskGroup(of: Void.self) { group in
      for connection in connections.values {
        group.addTask {
          await connection.stop(with: .goingAway, reason: "The server is shutting down")
        }
      }
    }
    assert(connections.count == 0)
  }

  func accept(client: WebSocketServer.Client) {
    Task {
      guard let request = try? await client.request() else {
        return
      }

      if request.upgradeRequested {
        var options = WebSocket.Options()
        options.maximumIncomingMessageSize = 1024 * 1024
        guard let socket = try? await client.upgrade(options: options) else {
          return
        }
        let id = nextConnectionId
        nextConnectionId += 1
        let connection = Connection(with: id, socket: socket)
        connections[id] = connection
        await connection.start().value
        connections[id] = nil
        return
      }

      guard request.method == .get && request.target == "/stats" else {
        await client.respond(with: .notFound, plainText: "The requested resource does not exist")
        return
      }
      await client.respond(with: .ok, plainText: "Number of connected WebSocket clients: \(connections.count)")
    }
  }
}

actor Connection {
  let id: ConnectionId
  let socket: WebSocket
  var mainTask: Task<Void, Never>?
  var watchdogTask: Task<Void, Never>?

  init(with id: ConnectionId, socket: WebSocket) {
    self.id = id
    self.socket = socket
  }

  func start() -> Task<Void, Never> {
    mainTask = Task {
      await run()
    }
    return mainTask!
  }

  func stop(with code: WebSocket.CloseCode = .goingAway, reason: String = "") async {
    await socket.close(with: code, reason: reason)
    await mainTask?.value
  }

  private func run() async {
    resetWatchdog()
    do {
      for try await event in socket {
        switch event {
          case .open(_):
            await socket.send(text: "Welcome to the echo server.")
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
