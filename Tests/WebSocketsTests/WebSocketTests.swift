// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import XCTest
import WebSockets

fileprivate let thirdPartyServerURL = URL(string: "wss://echo.websocket.events")!

class WebSocketTests: XCTestCase {
  private static let localServer = TestServer()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
  }

  func testPingOnLocalServer() async throws {
    let url = try await Self.localServer.start()
    try await randomPingTest(url: url)
  }

  func testPingOnThirdPartyServer() async throws {
    try await randomPingTest(url: thirdPartyServerURL)
  }

  func testRandomDataOnLocalServer() async throws {
    let sizes = [ 0, 1, 16, 64, 125, 126, 127, 128, 65535, 65536, 65537, 999_999 ]
    let url = try await Self.localServer.start()
    try await randomDataTest(url: url, sizes: sizes)
  }

  func testRandomDataOnThirdPartyServer() async throws {
    let sizes = [ 0, 1, 16, 64, 125, 126, 127, 128, 65535, 65536, 65537, 999_999 ]
    try await randomDataTest(url: thirdPartyServerURL, sizes: sizes)
  }

  func randomDataTest(url: URL, sizes: [Int]) async throws {
    let socket = WebSocket(url: url)
    let expected = sizes.map { randomData(size: $0) }
    var received: [Data] = []
    var receivedClose = false
    for data in expected {
      await socket.send(data: data)
    }
    await socket.close()
    for try await event in socket {
      switch event {
        case .binary(let data):
          received.append(data)
        case .close(code: _, reason: _, wasClean: let wasClean):
          XCTAssert(wasClean)
          receivedClose = true
        default:
          break
      }
    }
    XCTAssert(received == expected)
    XCTAssert(receivedClose)
  }

  func randomPingTest(url: URL) async throws {
    let socket = WebSocket(url: url)
    let expected = [0, 1, 16, 32, 64, 125 ].map { randomData(size: $0) }
    var received: [Data] = []
    var receivedClose = false
    for try await event in socket {
      switch event {
        case .open(_):
          for data in expected {
            await socket.ping(data: data)
          }
          await socket.close()
        case .pong(let data):
          received.append(data)
        case .close(code: _, reason: _, wasClean: let wasClean):
          XCTAssert(wasClean)
          receivedClose = true
        default:
          break
      }
    }
    XCTAssert(received == expected)
    XCTAssert(receivedClose)

  }

  actor TestServer {
    let server: WebSocketServer
    var started = false

    init() {
      server = WebSocketServer()
    }

    func start() async throws -> URL {
      if !started {
        started = true
        for try await event in server {
          if case .ready = event {
            break
          }
        }
        Task {
          for try await event in server {
            switch event {
              case .request(let request):
                await handleRequest(request)
              default:
                break
            }
          }
        }
      }
      return URL(string: "ws://localhost:\(server.port)")!
    }

    func stop() async {
      await server.stop()
    }

    private func handleRequest(_ request: WebSocketServer.Request) async {
      if request.upgradeRequested {
        guard let socket = await request.upgrade() else {
          return
        }
        handleSocket(socket)
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
}
