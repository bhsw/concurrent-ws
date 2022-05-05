import Foundation

// TODO:
// General approach:
//  1. Accept a connection from the listener.
//  2. Read the HTTP request from the client.
//  3. Package it up into a request event that gives the event handler a Request object with the following:
//      - HTTP method
//      - Path or URL
//      - Whether an upgrade to WebSocket is being requested, and if so, the list of subprotocols understood by the client
//      - Any extra headers
//      - An async method to complete the WebSocket handshake and return a `WebSocket` instance
//      - A method that can be called instead to send a generic HTTP response to the client
public actor WebSocketServer {
  public enum Event {
    case ready
    case networkUnavailable
    case client(Client)
  }

  public enum ServerError: Error {
    case listenerFailed(reason: String, underlyingError: Error)
  }

  private let listener: Listener

  public init(port: UInt16) {
    listener = Listener(port: port)
  }
}

  // MARK: AsyncSequence conformance

extension WebSocketServer : AsyncSequence, AsyncIteratorProtocol {
  public typealias Element = Event

  /// Gets the asynchronous iterator that can be used to loop over events emitted by the server.
  /// - Returns: The iterator.
  public nonisolated func makeAsyncIterator() -> WebSocketServer {
    return self
  }

  public func next() async throws -> Event? {
    do {
      for try await event in listener {
        switch event {
          case .ready:
            return .ready
          case .networkUnavailable:
            return .networkUnavailable
          case .connection(let connection):
            return .client(.init(from: connection))
        }
      }
    } catch ListenerError.failed(reason: let reason, underlyingError: let error) {
      throw ServerError.listenerFailed(reason: reason, underlyingError: error)
    }
    return nil
  }
}

// MARK: Client

extension WebSocketServer {
  public struct Request {
    public let method: WebSocket.HTTPMethod
    public let target: String
    public let host: String?
    public let extraHeaders: [String: String]
    public let contentType: WebSocket.ContentType?
    public let content: Data?
    public let upgradeRequested: Bool
    public let subprotocols: [String]
      // TODO: endpoint info
  }

  public struct Response {
    public var status: WebSocket.HTTPStatus
    public var location: String?
    public var extraHeaders: [String: String] = [:]
    public var contentType: WebSocket.ContentType?
    public var content: Data?

    public init(with status: WebSocket.HTTPStatus = .noContent) {
      self.status = status
    }
  }

  public actor Client {
    enum State {
      case initialized
      case readingRequest
      case pendingResponse
      case sendingResponse
      case done
    }

    private let connection: Connection
    private var state: State = .initialized
    private var request: Request?
    private var unconsumed: Data?

    init(from connection: Connection) {
      self.connection = connection
    }

    deinit {
      // In case the Client is dropped without sending a response.
      print("* Client deinit")
      connection.close()
    }

    public func request() async throws -> Request {
      guard state == .initialized else {
        fatalError("The HTTP request has already been retrieved")
      }
      state = .readingRequest
      var parser = HTTPMessage.Parser()
      do {
        for try await event in connection {
          switch event {
            case .receive(let data):
              switch parser.append(data) {
                case .incomplete:
                  continue
                case .invalid:
                  throw WebSocket.HandshakeError.invalidHTTPRequest
                case .complete(let message, unconsumed: let unconsumed):
                  guard message.kind == .request else {
                    throw WebSocket.HandshakeError.invalidHTTPRequest
                  }
                  self.unconsumed = unconsumed
                  self.request = Request(method: message.method!, target: message.target!,
                                         host: message.host, extraHeaders: message.extraHeaders,
                                         contentType: WebSocket.ContentType(from: message.contentType),
                                         content: message.content,
                                         upgradeRequested: message.upgrade.contains(.init("websocket")),
                                         subprotocols: message.webSocketProtocol)
                  state = .pendingResponse
                  return self.request!
              }
            default:
              break
          }
        }
        throw WebSocket.HandshakeError.invalidHTTPRequest
      } catch {
        state = .done
        throw error
      }
    }

    public func respond(with response: Response) async throws {
      guard state == .pendingResponse else {
        fatalError("Attempt to send more than one response to an HTTP request")
      }
      state = .sendingResponse
      var message = HTTPMessage(status: response.status, reason: response.status.description)
      if response.status.kind == .redirection, let location = response.location {
        message.location = location
      }
      message.extraHeaders = response.extraHeaders
      if response.status.allowsContent, let content = response.content {
        message.contentLength = content.count
        if request!.method != .head {
          message.content = content
        }
        if let contentType = response.contentType {
          var token = ParameterizedToken(token: contentType.mediaType)
          token.set(parameter: "charset", to: contentType.charset)
          message.contentType = token
        }
      }
      guard let data = message.encode() else {
        throw WebSocket.HandshakeError.invalidHTTPResponse
      }
      defer {
        connection.close()
        state = .done
      }
      await connection.send(data: data)
    }

    public func upgrade() async throws -> WebSocket {
      fatalError("Not implemented")
    }

    public func respond(withStatus status: WebSocket.HTTPStatus,
                        plainText text: String) async throws {
      var response = Response(with: status)
      response.contentType = .init(mediaType: "text/plain", charset: "utf-8")
      response.content = text.data(using: .utf8)
      try await respond(with: response)
    }

    public func badRequest(withPlainText text: String = "The request was invalid") async throws {
      try await respond(withStatus: .badRequest, plainText: text)
    }

    public func notFound(withPlainText text: String = "The specified resource could not be found") async throws {
      try await respond(withStatus: .notFound, plainText: text)
    }

    public func redirect(to location: String) async throws {
      var response = Response(with: .movedPermanently)
      response.location = location
      try await respond(with: response)
    }
  }
}
