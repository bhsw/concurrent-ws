import Foundation
import CryptoKit

fileprivate let supportedWebSocketVersion = 13
fileprivate let protocolUUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

extension WebSocket {
  /// The result of a successful WebSocket opening handshake.
  public struct HandshakeResult {
    /// The subprotocol confirmed by the other endpoint, or `nil` if no subprotocol is in effect.
    public let subprotocol: String?

    /// Any headers received in the HTTP response that were not pertinent to the WebSocket handshake. The dictionary maps lowercase header names to associated values.
    public let extraHeaders: [String: String]
  }

  /// The result of a failed WebSocket opening handshake.
  public struct FailedHandshakeResult {
    /// The HTTP status code.
    public let statusCode: Int

    /// The HTTP reason string.
    public let reason: String

    /// Any headers received in the HTTP response that were not pertinent to the WebSocket handshake. The dictionary maps lowercase header names to associated values.
    public let extraHeaders: [String: String]

    /// The content type of the response body, if any.
    public let contentType: ContentType?

    // The response body if one was provided.
    public let content: Data?
  }

  /// The content type of a response body.
  public struct ContentType {
    /// The media type (e.g. `text/plain`).
    public let mediaType: String

    /// The character set (e.g. `UTF-8`) used if the content is text.
    public let charset: String?
  }

  /// A type of error that may be thrown during the `connecting` state of the socket.
  public enum HandshakeError: Error {
    /// An attempt was made to connect to an invalid URL.
    case invalidURL(URL)

    /// An attempt was made to connect to an URL with a scheme other than `ws` or `wss`.
    case invalidURLScheme(String)

    /// The requested hostname could not be resolved to a valid address.
    case hostLookupFailed(reason: String, underlyingError: Error)

    /// The connection could not be established.
    case connectionFailed(reason: String, underlyingError: Error)

    /// Security for the connection could not be established.
    case tlsFailed(reason: String, underlyingError: Error)

    /// The HTTP request is invalid. This usually indicates that a custom header contains characters that cannot be encoded as ISO-8859-1.
    case invalidHTTPRequest

    /// A malformed HTTP response was received from the other endpoint during the handshake.
    case invalidHTTPResponse

    /// The server rejected the request to upgrade to the WebSocket protocol.
    case upgradeRejected

    /// The server's response did not include a valid `Connection` header.
    case invalidConnectionHeader

    /// The server did not provide the expected key.
    case keyMismatch

    /// The endpoints did not agree on a subprotocol.
    case subprotocolMismatch

    /// An extension was asserted by the other endpoint without negotiating for it.
    case extensionMismatch

    /// An HTTP redirect response did not include a valid `Location` header.
    case invalidRedirection

    /// The server responded with an unexpected status code.
    case unexpectedHTTPStatus(FailedHandshakeResult)

    /// The other endpoint dropped the connection before the handshake completed.
    case unexpectedDisconnect

    /// The handshake did not complete within the specified timeframe.
    case timeout

    /// The redirect limit was exceeded. This usually indicates a redirect loop.
    case maxRedirectsExceeded

    /// The redirect location was not a valid URL or relative URL.
    case invalidRedirectLocation(String)
  }
}

extension WebSocket {
  /// A WebSocket opening handshake state machine
  internal final class Handshake {
    enum Status {
      case incomplete
      case ready(result: HandshakeResult, unconsumed: Data)
      case redirect(String)
    }

    private typealias HandshakeError = WebSocket.HandshakeError
    private var options: WebSocket.Options
    private var expectedKey: String? = nil
    private var parser = HTTPMessage.Parser()

    init(options: WebSocket.Options) {
      self.options = options
    }

    func makeRequest(url: URL) throws -> Data {
      let key = generateKey()
      expectedKey = sha1(key + protocolUUID)

      var request = HTTPMessage(method: "GET", target: url.resourceName)
      request.host = url.hostAndPort
      request.addUpgrade(ProtocolIdentifier(name: "websocket"))
      request.webSocketKey = key
      if !options.subprotocols.isEmpty {
        request.webSocketProtocol = options.subprotocols
      }
      request.addWebSocketVersion(supportedWebSocketVersion)
      request.extraHeaders = options.extraHeaders
      guard let encoded = request.encode() else {
        throw HandshakeError.invalidHTTPRequest
      }
      return encoded
    }

    func receive(data: Data?) throws -> Status {
      switch parser.append(data) {
        case .incomplete:
          return .incomplete
        case .complete(let message, unconsumed: let data):
          return try handleResponse(message, unconsumed: data)
        case .invalid:
          throw HandshakeError.invalidHTTPResponse
      }
    }

    private func handleResponse(_ message: HTTPMessage, unconsumed: Data) throws -> Status {
      switch message.statusCode! {
        case 101:
          guard message.upgrade.contains(.init(name: "websocket")) == true else {
            throw HandshakeError.upgradeRejected
          }
          guard message.connection.contains(where: { $0.lowercased() == "upgrade" }) == true else {
            throw HandshakeError.invalidConnectionHeader
          }
          guard message.webSocketAccept == expectedKey else {
            throw HandshakeError.keyMismatch
          }
          let subprotocol = message.webSocketProtocol.first
          guard isAcceptableSubprotocol(subprotocol) else {
            throw HandshakeError.subprotocolMismatch
          }
          // We don't currently support any extensions, so ensure that the server is not specifying any.
          // (That would be a violation of the handshake protocol, as the server is required to select only
          // from extensions offered in the client's request.)
          guard message.webSocketExtensions.isEmpty else {
            throw HandshakeError.extensionMismatch
          }
          let result = HandshakeResult(subprotocol: subprotocol, extraHeaders: message.extraHeaders)
          return .ready(result: result, unconsumed: unconsumed)
        case 300...399:
          guard let location = message.location else {
            throw HandshakeError.invalidRedirection
          }
          return .redirect(location)
         default:
          let result = FailedHandshakeResult(statusCode: message.statusCode!,
                                             reason: message.reason ?? "",
                                             extraHeaders: message.extraHeaders,
                                             contentType: makeContentType(from: message.contentType),
                                             content: message.content)
          throw HandshakeError.unexpectedHTTPStatus(result)
      }
    }

    private func isAcceptableSubprotocol(_ subprotocol: String?) -> Bool {
      if let subprotocol = subprotocol {
        return options.subprotocols.contains(subprotocol)
      }
      return options.subprotocols.isEmpty
    }

    private func makeContentType(from token: ParameterizedToken?) -> ContentType? {
      guard let token = token else {
        return nil
      }
      return ContentType(mediaType: token.token, charset: token.get(parameter: "charset"))
    }
  }
}

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
