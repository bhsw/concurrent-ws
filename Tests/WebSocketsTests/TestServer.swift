// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation
import WebSockets

actor TestServer {
  let server: WebSocketServer
  let subprotocol: String?
  let httpResponseDelay: TimeInterval

  init(subprotocol: String? = nil, httpResponseDelay: TimeInterval = 0, httpRequestTimeout: TimeInterval = 30) {
    var options = WebSocketServer.Options()
    options.requestTimeout = httpRequestTimeout
    server = WebSocketServer(options: options)
    self.subprotocol = subprotocol
    self.httpResponseDelay = httpResponseDelay
  }

  func start(path: String = "") async throws -> URL {
    for try await event in server {
      if case .ready = event {
        break
      }
    }
    Task {
      for try await event in server {
        switch event {
          case .request(let request):
            if httpResponseDelay != 0 {
              try await Task.sleep(nanoseconds: UInt64(httpResponseDelay * 1_000_000_000))
            }
            await handleRequest(request)
          default:
            break
        }
      }
    }
    return URL(string: "ws://localhost:\(server.port)\(path)")!
  }

  func stop() async {
    await server.stop()
  }

  private func handleRequest(_ request: WebSocketServer.Request) async {
    if request.upgradeRequested {
      switch request.target {
        case "/404":
          await request.respond(with: .notFound, plainText: "Resource not found")
        case "/redirect":
          await request.redirect(to: "/test")
        case "/redirect-loop":
          await request.redirect(to: "/redirect-loop")
        case "/invalid-redirect-location":
          await request.redirect(to: " ")
        case "/missing-redirect-location":
          let response = WebSocketServer.Response(with: .movedPermanently)
          await request.respond(with: response)
        case "/test":
          guard let socket = await request.upgrade(subprotocol: subprotocol) else {
            return
          }
          handleSocket(socket)
        default:
          await request.respond(with: .notFound, plainText: "The specified resource was not found")
      }
      return
    }
    await request.respond(with: .badRequest, plainText: "Expected a WebSocket upgrade request")
  }

  private func handleSocket(_ socket: WebSocket) {
    Task {
      for try await event in socket {
        switch event {
          case .text(let str):
            await socket.send(text: str)
          case .binary(let data):
            await socket.send(data: data)
          default:
            break
        }
      }
    }
  }
}
