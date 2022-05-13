// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import XCTest
@testable import WebSockets

fileprivate let thirdPartyServerURL = URL(string: "wss://echo.websocket.events")!

class WebSocketTests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
  }

  func testTextMessage() async throws {
    let server = TestServer()
    defer {
      Task {
        await server.stop()
      }
    }
    let url = try await server.start(path: "/test")
    let socket = WebSocket(url: url)
    await socket.send(text: "Hello, world")
    let longText = String(repeating: "Hello, world. ", count: 1000)
    await socket.send(text: longText)
    await socket.close()
    var events = [WebSocket.Event]()
    for try await event in socket {
      events.append(event)
    }
    let expectedEvents: [WebSocket.Event] = [
      .open(.init(subprotocol: nil, compressionAvailable: true, extraHeaders: [:])),
      .text("Hello, world"),
      .text(longText),
      .close(code: .normalClosure, reason: "", wasClean: true)
    ]
    XCTAssertEqual(events, expectedEvents)

    let inStats = await socket.inputStatistics, outStats = await socket.outputStatistics
    var expectedStats = WebSocket.Statistics()
    expectedStats.controlFrameCount = 1
    expectedStats.textMessageCount = 2
    expectedStats.textBytesTransferred = 66
    expectedStats.compressedTextMessageCount = 2
    expectedStats.compressedTextBytesTransferred = 66
    expectedStats.compressedTextBytesSaved = 13946
    XCTAssertEqual(inStats, expectedStats)
    XCTAssertEqual(outStats, expectedStats)
  }

  func testTextMessageNoCompression() async throws {
    let server = TestServer()
    defer {
      Task {
        await server.stop()
      }
    }
    let url = try await server.start(path: "/test")
    var options = WebSocket.Options()
    options.enableCompression = false
    let socket = WebSocket(url: url, options: options)
    await socket.send(text: "Hello, world")
    let longText = String(repeating: "Hello, world. ", count: 1000)
    await socket.send(text: longText)
    await socket.close()
    var events = [WebSocket.Event]()
    for try await event in socket {
      events.append(event)
    }
    let expectedEvents: [WebSocket.Event] = [
      .open(.init(subprotocol: nil, compressionAvailable: false, extraHeaders: [:])),
      .text("Hello, world"),
      .text(longText),
      .close(code: .normalClosure, reason: "", wasClean: true)
    ]
    XCTAssertEqual(events, expectedEvents)

    let inStats = await socket.inputStatistics, outStats = await socket.outputStatistics
    var expectedStats = WebSocket.Statistics()
    expectedStats.controlFrameCount = 1
    expectedStats.textMessageCount = 2
    expectedStats.textBytesTransferred = 14012
    expectedStats.compressedTextMessageCount = 0
    expectedStats.compressedTextBytesTransferred = 0
    expectedStats.compressedTextBytesSaved = 0
    XCTAssertEqual(inStats, expectedStats)
    XCTAssertEqual(outStats, expectedStats)
  }

  func testTextMessageLimitedCompression() async throws {
    let server = TestServer()
    defer {
      Task {
        await server.stop()
      }
    }
    let url = try await server.start(path: "/test")
    var options = WebSocket.Options()
    options.textAutoCompressionRange = 8..<1000
    let socket = WebSocket(url: url, options: options)
    await socket.send(text: "Hello, world")
    let longText = String(repeating: "Hello, world. ", count: 1000)
    await socket.send(text: longText)
    await socket.close()
    var events = [WebSocket.Event]()
    for try await event in socket {
      events.append(event)
    }
    let expectedEvents: [WebSocket.Event] = [
      .open(.init(subprotocol: nil, compressionAvailable: true, extraHeaders: [:])),
      .text("Hello, world"),
      .text(longText),
      .close(code: .normalClosure, reason: "", wasClean: true)
    ]
    XCTAssertEqual(events, expectedEvents)

    let inStats = await socket.inputStatistics, outStats = await socket.outputStatistics
    var expectedStats = WebSocket.Statistics()
    expectedStats.controlFrameCount = 1
    expectedStats.textMessageCount = 2
    expectedStats.textBytesTransferred = 14014
    expectedStats.compressedTextMessageCount = 1
    expectedStats.compressedTextBytesTransferred = 14
    expectedStats.compressedTextBytesSaved = -2
    XCTAssertEqual(outStats, expectedStats)
    expectedStats.textBytesTransferred = 66
    expectedStats.compressedTextMessageCount = 2
    expectedStats.compressedTextBytesTransferred = 66
    expectedStats.compressedTextBytesSaved = 13946
    XCTAssertEqual(inStats, expectedStats)
  }

  func testBinaryMessage() async throws {
    let server = TestServer()
    defer {
      Task {
        await server.stop()
      }
    }
    let url = try await server.start(path: "/test")
    let socket = WebSocket(url: url)
    let payload1 = patternData(size: 999), payload2 = patternData(size: 9999), payload3 = randomData(size: 999)
    await socket.send(data: payload1)
    await socket.send(data: payload2)
    await socket.send(data: payload3)
    await socket.close()
    var events = [WebSocket.Event]()
    for try await event in socket {
      events.append(event)
    }
    let expectedEvents: [WebSocket.Event] = [
      .open(.init(subprotocol: nil, compressionAvailable: true, extraHeaders: [:])),
      .binary(payload1),
      .binary(payload2),
      .binary(payload3),
      .close(code: .normalClosure, reason: "", wasClean: true)
    ]
    XCTAssertEqual(events, expectedEvents)

    let inStats = await socket.inputStatistics, outStats = await socket.outputStatistics
    var expectedStats = WebSocket.Statistics()
    expectedStats.controlFrameCount = 1
    expectedStats.binaryMessageCount = 3
    expectedStats.binaryBytesTransferred = 1344
    expectedStats.compressedBinaryMessageCount = 3
    expectedStats.compressedBinaryBytesTransferred = 1344
    expectedStats.compressedBinaryBytesSaved = 10653
    XCTAssertEqual(inStats, expectedStats)
    XCTAssertEqual(outStats, expectedStats)
  }


  func testPingOnLocalServer() async throws {
    let server = TestServer()
    defer {
      Task {
        await server.stop()
      }
    }
    let url = try await server.start(path: "/test")
    try await randomPingTest(url: url)
  }

  func testPingOnThirdPartyServer() async throws {
    try await randomPingTest(url: thirdPartyServerURL)
  }

  func testRandomDataOnLocalServer() async throws {
    let server = TestServer()
    defer {
      Task {
        await server.stop()
      }
    }
    let sizes = [ 0, 1, 16, 64, 125, 126, 127, 128, 65535, 65536, 65537, 999_999, 3_999_999 ]
    let url = try await server.start(path: "/test")
    try await randomDataTest(url: url, sizes: sizes)
  }

  func testRandomDataOnThirdPartyServer() async throws {
    let sizes = [ 0, 1, 16, 64, 125, 126, 127, 128, 65535, 65536, 65537, 999_999 ]
    try await randomDataTest(url: thirdPartyServerURL, sizes: sizes)
  }

  func testMaximumIncomingMessageSizeOption() async throws {
    let server = TestServer()
    defer {
      Task {
        await server.stop()
      }
    }
    var options = WebSocket.Options()
    options.enableCompression = false
    options.maximumIncomingMessagePayloadSize = 128 * 1024
    let socket = WebSocket(url: try await server.start(path: "/test"), options: options)
    let validData = randomData(size: 128 * 1024)
    await socket.send(data: validData)
    await socket.send(data: randomData(size: 128 * 1024 + 1))
    await socket.close()
    var events: [WebSocket.Event] = []
    for try await event in socket {
      events.append(event)
    }
    let expected: [WebSocket.Event] = [
      .open(.init(subprotocol: nil, compressionAvailable: false, extraHeaders: [:])),
      .binary(validData),
      .close(code: .policyViolation, reason: "Maximum message size exceeded", wasClean: false)
    ]
    XCTAssertEqual(events, expected)
  }

  func testSubprotocolOneFromList() async throws {
    let server = TestServer(subprotocol: "second")
    defer {
      Task {
        await server.stop()
      }
    }

    var options = WebSocket.Options()
    options.subprotocols = [ "first", "second", "third" ]
    let socket = WebSocket(url: try await server.start(path: "/test"), options: options)
    await socket.send(text: "Hello")
    await socket.close()
    var closed = false
    for try await event in socket {
      switch event {
        case .open(let result):
          XCTAssertEqual(result.subprotocol, "second")
        case .close(code: _, reason: _, wasClean: let wasClean):
          XCTAssert(wasClean)
          closed = true
        default:
          break;
      }
    }
    XCTAssert(closed)
  }

  func testSubprotocolNoneFromList() async throws {
    let server = TestServer(subprotocol: nil)
    defer {
      Task {
        await server.stop()
      }
    }

    var options = WebSocket.Options()
    options.subprotocols = [ "first", "second", "third" ]
    let socket = WebSocket(url: try await server.start(path: "/test"), options: options)
    await socket.send(text: "Hello")
    await socket.close()
    var closed = false
    for try await event in socket {
      switch event {
        case .open(let result):
          XCTAssertEqual(result.subprotocol, nil)
        case .close(code: _, reason: _, wasClean: let wasClean):
          XCTAssert(wasClean)
          closed = true
        default:
          break;
      }
    }
    XCTAssert(closed)
  }

  func testUnexpectedSubprotocol() async throws {
    let server = TestServer(subprotocol: "nope")
    defer {
      Task {
        await server.stop()
      }
    }

    let socket = WebSocket(url: try await server.start(path: "/test"))
    await socket.send(text: "Hello")
    await socket.close()
    do {
      for try await _ in socket {
      }
      XCTFail("Expected an exception ")
    } catch WebSocketError.subprotocolMismatch {
    }
  }

  func testJustClosingNeverOpens() async throws {
    let socket = WebSocket(url: URL(string: "ws://localhost")!)         // The actual URL won't be used in this case
    await socket.close()
    let event = try await socket.makeAsyncIterator().next()
    XCTAssert(event == nil)
  }

  func testOpeningHandshakeTimeout() async throws {
    let server = TestServer(httpResponseDelay: 10)
    defer {
      Task {
        await server.stop()
      }
    }
    var options = WebSocket.Options()
    options.openingHandshakeTimeout = 1
    let socket = WebSocket(url: try await server.start(), options: options)
    await socket.send(text: "Hello")
    await socket.close()
    do {
      for try await _ in socket {
      }
      XCTFail("Expected an exception ")
    } catch WebSocketError.timeout {
    }
  }

  func testUnexpectedHandshakeDisconnect() async throws {
    let server = TestServer(httpRequestTimeout: 0)
    defer {
      Task {
        await server.stop()
      }
    }
    let socket = WebSocket(url: try await server.start())
    await socket.send(text: "Hello")
    await socket.close()
    do {
      for try await _ in socket {
      }
      XCTFail("Expected an exception ")
    } catch WebSocketError.unexpectedDisconnect {
    }
  }

  func testInvalidURL() async throws {
    let socket = WebSocket(url: URL(string: "wss://")!)
    await socket.send(text: "Hello")
    do {
      for try await _ in socket {
      }
      XCTFail("Expected an exception ")
    } catch WebSocketError.invalidURL {
    }
  }

  func testInvalidURLScheme() async throws {
    let socket = WebSocket(url: URL(string: "http://localhost")!)
    await socket.send(text: "Hello")
    do {
      for try await _ in socket {
      }
      XCTFail("Expected an exception ")
    } catch WebSocketError.invalidURLScheme {
    }
  }

  func testHostLookupFailure() async throws {
    let socket = WebSocket(url: URL(string: "ws://nope.ocsoft.com")!)
    await socket.send(text: "Hello")
    do {
      for try await _ in socket {
      }
      XCTFail("Expected an exception ")
    } catch WebSocketError.hostLookupFailed {
    }
  }

  func testConnectionFailure() async throws {
    let socket = WebSocket(url: URL(string: "ws://ocsoft.com:500")!)
    await socket.send(text: "Hello")
    do {
      for try await _ in socket {
      }
      XCTFail("Expected an exception ")
    } catch WebSocketError.connectionFailed {
    }
  }

  func testTLSFailure() async throws {
    let socket = WebSocket(url: URL(string: "wss://ocsoft.com:80")!)
    await socket.send(text: "Hello")
    do {
      for try await _ in socket {
      }
      XCTFail("Expected an exception ")
    } catch WebSocketError.tlsFailed {
    }
  }

  func testUpgradeRejected() async throws {
    do {
      try await expectingErrorFromLocalServer(path: "/404")
    } catch WebSocketError.upgradeRejected(let result) {
      XCTAssertEqual(result.status, .notFound)
    }
  }

  func testRedirect() async throws {
    let server = TestServer(subprotocol: nil)
    defer {
      Task {
        await server.stop()
      }
    }

    let socket = WebSocket(url: try await server.start(path: "/redirect"))
    await socket.send(text: "Hello")
    await socket.close()
    for try await _ in socket {
    }
    let path = await socket.url.path
    XCTAssertEqual(path, "/test")
  }

  func testRedirectionDisabled() async throws {
    var options = WebSocket.Options()
    options.maximumRedirects = 0
    do {
      try await expectingErrorFromLocalServer(path: "/redirect", options: options)
    } catch WebSocketError.maximumRedirectsExceeded {
    }
  }

  func testInvalidRedirectLocation() async throws {
    do {
      try await expectingErrorFromLocalServer(path: "/invalid-redirect-location")
    } catch WebSocketError.invalidRedirectLocation {
    }
  }

  func testMissingRedirectLocation() async throws {
    do {
      try await expectingErrorFromLocalServer(path: "/missing-redirect-location")
    } catch WebSocketError.invalidRedirection {
    }
  }

  func testRedirectLoop() async throws {
    do {
      try await expectingErrorFromLocalServer(path: "/redirect-loop")
    } catch WebSocketError.maximumRedirectsExceeded {
    }
  }

  func testKeyMismatch() async throws {
    do {
      try await expectingErrorDueToDefectiveServer(with: .incorrectKey)
    } catch WebSocketError.keyMismatch {
    }
  }

  func testExtensionMismatch() async throws {
    do {
      try await expectingErrorDueToDefectiveServer(with: .badExtension)
    } catch WebSocketError.extensionMismatch {
    }
  }

  func testInvalidConnectionHeader() async throws {
    do {
      try await expectingErrorDueToDefectiveServer(with: .invalidConnectionHeader)
    } catch WebSocketError.invalidConnectionHeader {
    }
  }

  func testInvalidUpgradeHeader() async throws {
    do {
      try await expectingErrorDueToDefectiveServer(with: .invalidUpgradeHeader)
    } catch WebSocketError.invalidUpgradeHeader {
    }
  }

  func testInvalidHTTPResponse() async throws {
    do {
      try await expectingErrorDueToDefectiveServer(with: .invalidHTTPResponse)
    } catch WebSocketError.invalidHTTPResponse {
    }
  }

  func testMaskedFrameFromServerFailsConnection() async throws {
    try await expectCloseCode(quirk: .sendMaskedFrame, code: .protocolError, reason: "Masked payload forbidden")
  }

  func testInvalidOpcodeFromServerFailsConnection() async throws {
    try await expectCloseCode(quirk: .sendInvalidOpcode, code: .protocolError, reason: "Invalid opcode")
  }

  func testInvalidUTF8FromServerFailsConnection() async throws {
    try await expectCloseCode(quirk: .sendInvalidUTF8, code: .protocolError, reason: "Invalid UTF-8 data")
  }

  func testUnexpectedContinuationFrameFromServerFailsConnection() async throws {
    try await expectCloseCode(quirk: .sendUnexpectedContinuation, code: .protocolError,
                              reason: "Unexpected continuation frame")
  }

  func testNonzeroReservedBitsFromServerFailsConnection() async throws {
    try await expectCloseCode(quirk: .sendNonzeroReservedBits, code: .protocolError, reason: "Reserved bits must be 0")
  }

  func testInvalidPayloadLengthFromServerFailsConnection() async throws {
    try await expectCloseCode(quirk: .sendInvalidPayloadLength, code: .protocolError, reason: "Invalid payload length")
  }

  func testInvalidCompressionDatafromServerFailsConnection() async throws {
    try await expectCloseCode(quirk: .sendInvalidCompressedMessage, code: .protocolError, reason: "Invalid compressed data")
  }

  func testInvalidCompressedOpcodeFromServerFailsConnection() async throws {
    try await expectCloseCode(quirk: .sendInvalidCompressedOpcode, code: .protocolError, reason: "Forbidden opcode for compression")
  }

  func testFragmentedMessageFromServer() async throws {
    let server = QuirkyTestServer(with: .sendFragmentedMessage)
    defer {
      Task {
        await server.stop()
      }
    }
    let socket = WebSocket(url: try await server.start())
    await socket.send(text: "Hello")
    var events: [WebSocket.Event] = []
    for try await event in socket {
      events.append(event)
    }
    let expected: [WebSocket.Event] = [
      .open(.init(subprotocol: nil, compressionAvailable: true, extraHeaders: [:])),
      .text("Hello, world."),
      .close(code: .goingAway, reason: "", wasClean: false)         // Quirky server disconnects right after sending close frame
    ]
    XCTAssert(events == expected)
  }

  func expectCloseCode(quirk: QuirkyTestServer.Quirk, code: WebSocket.CloseCode, reason: String? = nil) async throws {
    let server = QuirkyTestServer(with: quirk)
    defer {
      Task {
        await server.stop()
      }
    }
    let socket = WebSocket(url: try await server.start())
    await socket.send(text: "Hello")
    for try await event in socket {
      switch event {
        case .close(code: let inCode, reason: let inReason, wasClean: _):
          XCTAssert(inCode == code)
          if let reason = reason {
            XCTAssert(inReason == reason)
          }
        default:
          break
      }
    }
  }

  func expectingErrorFromLocalServer(path: String, options: WebSocket.Options = .init()) async throws {
    let server = TestServer()
    defer {
      Task {
        await server.stop()
      }
    }
    let socket = WebSocket(url: try await server.start(path: path), options: options)
    await socket.send(text: "Hello")
    await socket.close()
    for try await _ in socket {
    }
    XCTFail("Expected an exception ")
  }

  func expectingErrorDueToDefectiveServer(with quirk: QuirkyTestServer.Quirk) async throws {
    let server = QuirkyTestServer(with: quirk)
    defer {
      Task {
        await server.stop()
      }
    }
    let socket = WebSocket(url: try await server.start())
    await socket.send(text: "Hello")
    for try await _ in socket {
    }
    XCTFail("Expected an exception ")
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
}
