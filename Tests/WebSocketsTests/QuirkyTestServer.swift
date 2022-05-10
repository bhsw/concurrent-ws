// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation
@testable import WebSockets

actor QuirkyTestServer {
  enum Quirk {
    case incorrectKey
    case badExtension
    case invalidUpgradeHeader
    case invalidConnectionHeader
    case invalidHTTPResponse
    case sendMaskedFrame
    case sendInvalidOpcode
    case sendInvalidUTF8
    case sendUnexpectedContinuation
    case sendNonzeroReservedBits
    case sendInvalidPayloadLength
    case sendFragmentedMessage
  }

  let quirk: Quirk
  let listener: Listener

  init(with quirk: Quirk) {
    self.quirk = quirk
    listener = Listener(port: 0)
  }

  func start() async throws -> URL {
    for try await event in listener {
      if case .ready = event {
        break
      }
    }
    Task {
      for try await event in listener {
        switch event {
          case .connection(let connection):
            serve(connection: connection)
          default:
            break
        }
      }
    }
    return URL(string: "ws://localhost:\(listener.port)")!
  }

  func stop() {
    listener.stop()
  }

  private func serve(connection: Connection) {
    Task {
      var parser = HTTPMessage.Parser()
      do {
        for try await event in connection {
          switch event {
            case .receive(let data):
              switch parser.append(data) {
                case .incomplete:
                  continue
                case .invalid:
                  throw WebSocketError.invalidHTTPRequest
                case .complete(let message, unconsumed: _):
                  guard message.kind == .request else {
                    throw WebSocketError.invalidHTTPRequest
                  }
                  await handle(message: message, on: connection)
              }
            default:
              break
          }
        }
      } catch {
        connection.close()
      }
      print("*** exit serve ***")
    }
  }

  private func handle(message: HTTPMessage, on connection: Connection) async {
    var response = makeServerHandshakeResponse(to: message, subprotocol: nil)
    switch quirk {
      case .incorrectKey:
        response.webSocketAccept! += "x"
      case .badExtension:
        response.addWebSocketExtension(.init(token: "some-invalid-extension-identifier"))
      case .invalidUpgradeHeader:
        response.upgrade = []
      case .invalidConnectionHeader:
        response.connection = []
      case .invalidHTTPResponse:
        await connection.send(data: "Invalid\r\n\r\n".data(using: .isoLatin1)!)
        return
      default:
        break
    }
    await connection.send(data: response.encode())
    switch quirk {
      case .sendMaskedFrame:
        let frame: [UInt8] = [ 0x82, 0x81, 0x00, 0x00, 0x00, 0x00, 0x01 ]
        await connection.send(data: Data(frame))
      case .sendInvalidOpcode:
        let frame: [UInt8] = [ 0x84, 0x01, 0x00 ]
        await connection.send(data: Data(frame))
      case .sendInvalidUTF8:
        let frame: [UInt8] = [ 0x81, 0x01, 0x81 ]
        await connection.send(data: Data(frame))
      case .sendUnexpectedContinuation:
        let frame: [UInt8] = [ 0x00, 0x01, 0x00 ]
        await connection.send(data: Data(frame))
      case .sendNonzeroReservedBits:
        let frame: [UInt8] = [ 0xc2, 0x01, 0x00 ]
        await connection.send(data: Data(frame))
      case .sendInvalidPayloadLength:
        let frame: [UInt8] = [ 0x82, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff ]
        await connection.send(data: Data(frame))
      case .sendFragmentedMessage:
        let frame: [UInt8] = [ 0x01, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f,                // .text("Hello")
                               0x00, 0x02, 0x2c, 0x20,                                  // .text(", ")
                               0x80, 0x06, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0x2e,          // .text("world.")
                               0x88, 0x02, 0x03, 0xe9 ]                                 // .close(.goingAway)
        await connection.send(data: Data(frame))
      default:
        break
    }
  }
}
