// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation
import CryptoKit

fileprivate let supportedWebSocketVersion = 13
fileprivate let protocolUUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
internal let websocketProtocol = ProtocolIdentifier("websocket")

// MARK: ClientHandshake

/// A WebSocket opening handshake state machine
internal final class ClientHandshake {
  enum Status {
    case incomplete
    case ready(result: WebSocket.HandshakeResult, unconsumed: Data)
    case redirect(String)
  }

  private var options: WebSocket.Options
  private var expectedKey: String? = nil
  private var parser = HTTPMessage.Parser()

  init(options: WebSocket.Options) {
    self.options = options
  }

  func makeRequest(url: URL) -> Data {
    let key = generateKey()
    expectedKey = sha1(key + protocolUUID)

    var request = HTTPMessage(method: .get, target: url.resourceName)
    request.host = url.hostAndPort
    request.addUpgrade(websocketProtocol)
    request.webSocketKey = key
    if !options.subprotocols.isEmpty {
      request.webSocketProtocol = options.subprotocols
    }
    request.addWebSocketVersion(supportedWebSocketVersion)
    request.extraHeaders = options.extraHeaders
    return request.encode()
  }

  func receive(data: Data?) throws -> Status {
    switch parser.append(data) {
      case .incomplete:
        return .incomplete
      case .complete(let message, unconsumed: let data):
        return try handleResponse(message, unconsumed: data)
      case .invalid:
        throw WebSocketError.invalidHTTPResponse
    }
  }

  private func handleResponse(_ message: HTTPMessage, unconsumed: Data) throws -> Status {
    if message.status!  == .switchingProtocols {
      guard message.upgrade.contains(websocketProtocol) == true else {
        throw WebSocketError.upgradeRejected
      }
      guard message.connection.contains(where: { $0.lowercased() == "upgrade" }) == true else {
        throw WebSocketError.invalidConnectionHeader
      }
      guard message.webSocketAccept == expectedKey else {
        throw WebSocketError.keyMismatch
      }
      let subprotocol = message.webSocketProtocol.first
      guard subprotocol == nil || options.subprotocols.contains(subprotocol!) else {
        throw WebSocketError.subprotocolMismatch
      }
      // We don't currently support any extensions, so ensure that the server is not specifying any.
      // (That would be a violation of the handshake protocol, as the server is required to select only
      // from extensions offered in the client's request.)
      guard message.webSocketExtensions.isEmpty else {
        throw WebSocketError.extensionMismatch
      }
      let result = WebSocket.HandshakeResult(subprotocol: subprotocol, extraHeaders: message.extraHeaders)
      return .ready(result: result, unconsumed: unconsumed)
    }

    if message.status!.kind == .redirection {
      guard let location = message.location else {
        throw WebSocketError.invalidRedirection
      }
      return .redirect(location)
    }

    let result = WebSocket.FailedHandshakeResult(status: message.status!,
                                                 reason: message.reason ?? "",
                                                 extraHeaders: message.extraHeaders,
                                                 contentType: ContentType(from: message.contentType),
                                                 content: message.content)
    throw WebSocketError.unexpectedHTTPStatus(result)
  }
}

// MARK: Server handshake

internal func makeServerHandshakeResponse(to request: HTTPMessage, subprotocol: String?,
                                          extraHeaders: [String: String] = [:]) -> HTTPMessage {
  guard request.version >= .v1_1 else {
    return failedUpgrade(text: "A WebSocket upgrade requires HTTP version 1.1 or greater")
  }
  guard request.method == .get else {
    return failedUpgrade(text: "A WebSocket upgrade requires a GET request")
  }
  guard request.upgrade.contains(websocketProtocol) else {
    return failedUpgrade(text: "Expected a WebSocket upgrade request")
  }
  guard request.connection.contains(where: { $0.lowercased() == "upgrade" }) == true else {
    return failedUpgrade(text: "Invalid connection header for WebSocket upgrade")
  }
  guard request.webSocketVersion == [ supportedWebSocketVersion] else {
    return failedUpgrade(text: "Expected WebSocket version \(supportedWebSocketVersion)")
  }
  guard let clientKey = request.webSocketKey else {
    return failedUpgrade(text: "Expected a Sec-WebSocket-Key header")
  }

  var response = HTTPMessage(status: .switchingProtocols)
  response.addUpgrade(websocketProtocol)
  response.addWebSocketVersion(supportedWebSocketVersion)
  response.webSocketAccept = sha1(clientKey + protocolUUID)
  if let subprotocol = subprotocol {
    response.addWebSocketProtocol(subprotocol)
  }
  response.extraHeaders = extraHeaders
  return response
}

private func failedUpgrade(status: HTTPStatus = .badRequest, text: String) -> HTTPMessage {
  var message = HTTPMessage(status: status, reason: status.description)
  message.contentType = .init(token: "text/plain")
  message.contentType!.set(parameter: "charset", to: "utf-8")
  message.content = text.data(using: .utf8)
  return message
}

// MARK: Key utilities

fileprivate func generateKey() -> String {
  var nonce = Data(count: 16)
  for index in 0..<nonce.count {
    nonce[index] = UInt8.random(in: 0...255)
  }
  return nonce.base64EncodedString()
}

fileprivate func sha1(_ input: String) -> String? {
  guard let data = input.data(using: .ascii) else {
    return nil
  }
  let digest = Insecure.SHA1.hash(data: data)
  return Data(Array(digest.makeIterator())).base64EncodedString()
}

// MARK: Private URL extension

fileprivate extension URL {
  var hostAndPort: String? {
    guard let host = self.host else {
      return nil
    }
    guard let port = self.port else {
      return host
    }
    return "\(host):\(port)"
  }

  var resourceName: String {
    let path = self.path.isEmpty ? "/" : self.path
    guard let query = self.query else {
      return path
    }
    return "\(path)?\(query)"
  }
}
