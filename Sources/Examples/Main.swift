// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation
@testable import WebSockets

@main
struct App {
  static func main() async {
    do {
//      try await testClient()
//      try await testSimpleClient()
//      try await testServer()
      try testZlib()
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
    } catch WebSocketError.upgradeRejected(let result) {
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

  static func testZlib() throws {
    let input: [UInt8] = [ 0x48, 0x65, 0x6c, 0x6c, 0x6f ]
//    let deflater = Deflater(sharedWindow: true)
//    var output = deflater.compress(input)
//    print(hex(output))

//    let inflater = Inflater(sharedWindow: true)
//    print(hex(try inflater.decompress(output)))

//    output = deflater.compress(input)
//    print(hex(output))
//    print(hex(try inflater.decompress(output)))

//    let emptyInput = [UInt8]()
//    let smallInput: [UInt8] = [ 1 ]
//    output = deflater.compress(smallInput)
//    print(hex(output))
//    let maybeSmallInput = try inflater.decompress(output)
//    assert(maybeSmallInput == Data(smallInput))

    var largeInput = patternedData(size: 1024 * 1024 * 30)
    print("Start append mask")
    var largeMasked = Data()
    largeMasked.append(largeInput, usingMask: 1234)
    print("Done append mask")
    print("Start in place mask")
    largeInput.mask(using: 1234, range: largeInput.indices)
    print("Done in place mask")
//    output = deflater.compress(largeInput)
//    print(largeInput.count, output.count)
//    let output2 = try inflater.decompress(output)
//    assert(largeInput == output2)

    var data = Data([ 0, 1, 2, 3, 4, 5, 6, 7 ])
    data.mask(using: 0xffffffff, range: data.startIndex + 4..<data.endIndex)
    print(hex(data))






    // This should throw
//    print(hex(try inflater.decompress(input)))
  }
}

func hex<T>(_ data: T) -> String where T: DataProtocol {
  var str = ""
  for c in data {
    str += String(c, radix: 16) + " "
  }
  return str
}

func randomData(size: Int) -> Data {
  var bytes: [UInt8] = []
  bytes.reserveCapacity(size)
  var index = 0
  while index < size {
    bytes.append(UInt8.random(in: 0...255))
    index += 1
  }
  return Data(bytes)
}

func patternedData(size: Int) -> Data {
  var bytes: [UInt8] = []
  bytes.reserveCapacity(size)
  var index = 0
  while index < size {
    bytes.append(UInt8(index & 255))
    index += 1
  }
  return Data(bytes)
}

extension Data {
  mutating func mask(using key: UInt32, range: Range<Data.Index>) {
    let mask: [UInt8] = [
      UInt8(key >> 24),
      UInt8(key >> 16 & 255),
      UInt8(key >> 8 & 255),
      UInt8(key & 255)
    ]
    self.withUnsafeMutableBytes { ptr in
      var index = range.startIndex
      var maskIndex = 0
      while index != range.endIndex {
        ptr[index] ^= mask[maskIndex & 3]
        index &+= 1
        maskIndex &+= 1
      }
    }
  }

  mutating func append<T : Collection>(_ data: T, usingMask key: UInt32) where T.Element == UInt8 {
    let mask: [UInt8] = [
      UInt8(key >> 24),
      UInt8(key >> 16 & 255),
      UInt8(key >> 8 & 255),
      UInt8(key & 255)
    ]
    reserveCapacity(count + data.count)
    var maskIndex = 0
    for c in data {
      append(c ^ mask[maskIndex & 3])
      maskIndex &+= 1
    }
  }
}

