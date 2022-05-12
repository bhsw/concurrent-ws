import XCTest
@testable import WebSockets

class WebSocketServerTests: XCTestCase {
  func testUnmaskedPayloadFromClientMustFailConnection() async throws {
    let server = TestServer(subprotocol: nil)
    defer {
      Task {
        await server.stop()
      }
    }
    let socket = QuirkyTestClient(url: try await server.start(path: "/test"), quirk: .sendUnmasked)
    try await socket.connect()
    await socket.close()

    var events: [WebSocket.Event] = []
    while let event = await socket.nextEvent() {
      events.append(event)
    }
    let expect: [WebSocket.Event] = [
      .open(.init(subprotocol: nil, compressionAvailable: true, extraHeaders: [:])),
      .close(code: .protocolError, reason: "Masked payload required", wasClean: false)
    ]
    XCTAssertEqual(events, expect)
  }

  func testInvalidHTTPVersion() async throws {
    try await expectUpgradeRejected(quirk: .invalidHTTPVersion,
                                    message: "A WebSocket upgrade requires HTTP version 1.1 or greater")
  }

  func testInvalidWebSocketProtocolVersion() async throws {
    try await expectUpgradeRejected(quirk: .invalidProtocolVersion, message: "Expected WebSocket version 13")
  }

  func testInvalidUpgradeHeader() async throws {
    try await expectUpgradeRejected(quirk: .invalidUpgradeHeader, message: "Expected a WebSocket upgrade request")
  }

  func testInvalidConnectionHeader() async throws {
    try await expectUpgradeRejected(quirk: .invalidConnectionHeader, message: "Invalid connection header for WebSocket upgrade")
  }

  func testInvalidHTTPMethod() async throws {
    try await expectUpgradeRejected(quirk: .invalidHTTPMethod, message: "A WebSocket upgrade requires a GET request")
  }

  func testMissingKeyHeader() async throws {
    try await expectUpgradeRejected(quirk: .missingKeyHeader, message: "Expected a Sec-WebSocket-Key header")
  }

  func expectUpgradeRejected(quirk: QuirkyTestClient.Quirk, message: String) async throws {
    let server = TestServer(subprotocol: nil)
    defer {
      Task {
        await server.stop()
      }
    }
    let socket = QuirkyTestClient(url: try await server.start(path: "/test"), quirk: quirk)
    do {
      try await socket.connect()
      XCTFail("An exception is expected")
    } catch WebSocketError.upgradeRejected(let result) {
      XCTAssertEqual(result.status, .badRequest)
      XCTAssertEqual(result.content, message.data(using: .utf8)!)
    }
  }
}
