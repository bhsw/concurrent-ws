// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation

/// A simple HTTP 1.1 server that supports upgrading connections to WebSockets.
public actor WebSocketServer {
  /// An event that has occured on a `WebSocketServer`.
  public enum Event {
    /// Indicates that the server is ready to accept requests.
    case ready

    /// Indicates that no network is currently available on which to receive requests.
    case networkUnavailable

    /// Indicates that a new connection has been received from an HTTP client.
    case client(Client)
  }

  private let listener: Listener

  /// Initializes a new `WebSocketServer` that listens on the specified port.
  /// - Parameter port: The port.
  public init(port: UInt16) {
    listener = Listener(port: port)
  }

  /// Stops accepting new connections.
  ///
  /// Any further attempts to iterate over the server's events will return `nil`.
  public func stop() {
    listener.stop()
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

  /// Gets the next available event.
  /// - Returns: The event, or `nil` if the server has been stopped.
  /// - Throws: ``WebSocketError/listenerFailed(reason:underlyingError:)`` if the connection listener fails.
  public func next() async throws -> Event? {
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
    return nil
  }
}

// MARK: Client

extension WebSocketServer {
  /// Information about an HTTP request.
  public struct Request {
    /// The HTTP method.
    public let method: HTTPMethod

    /// The request target (e.g. `/api/status`)
    public let target: String

    /// The value of the `Host` header, or `nil` if the request did not include that header.
    public let host: String?

    /// Additional headers included with the request.
    ///
    /// The dictionary maps header names to associated values.
    public let extraHeaders: [String: String]

    /// The content type associated with the body of the request, or `nil` if unspecified.
    public let contentType: ContentType?

    /// The body of the request, or `nil` if the request does not include a body.
    public let content: Data?

    /// Whether the client is requesting an upgrade to the WebSocket protocol.
    public let upgradeRequested: Bool

    /// The list of WebSocket subprotocols that the client would like to use, ordered from most preferred to least preferred.
    public let subprotocols: [String]
      // TODO: endpoint info
  }

  /// An HTTP response.
  public struct Response {
    /// The HTTP status code.
    public var status: HTTPStatus

    /// The `Location` header value, or `nil` to omit the header.
    public var location: String?

    /// The content type associated with the body of the response, or `nil` if unspecified.
    public var contentType: ContentType?

    /// Additional headers to include in the response.
    ///
    /// The dictionary maps header names to associated values.
    ///
    /// Note that headers that are relied upon to complete the handshake (such as `Sec-*` or `Upgrade`) are considered forbidden and will be ignored if included.
    public var extraHeaders: [String: String] = [:]

    /// The body of the response, or `nil` if the response does not have a body.
    public var content: Data?

    /// Initializes a response.
    /// - Parameter status: The HTTP status
    public init(with status: HTTPStatus = .noContent) {
      self.status = status
    }
  }

  /// A connection from a client accepted by a ``WebSocketServer``.
  ///
  /// Instances of `Client` are relatively short-lived and exist to allow incoming HTTP requests to be read and responded to by a `Task`
  /// separate from the server's own. The handler for a client can elect to send an ordinary HTTP response or upgrade the connection to a
  /// ``WebSocket``. After either action, the `Client` has served its purpose, and any references to it should be dropped.
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
    private var request: HTTPMessage?

    init(from connection: Connection) {
      self.connection = connection
    }

    deinit {
      print("* Client deinit")

      // In case the Client is dropped without sending a response.
      connection.close()
    }

    /// Reads the HTTP request from the client.
    ///
    /// This function should be called exactly once when the client is first provided by the ``WebSocketServer``. This should be done on a new `Task`
    /// so that the server is able to return to accepting connections in a timely manner.
    /// - Returns: The request.
    /// - Throws: ``WebSocketError`` if the request could not be read or is invalid.
    public func request() async throws -> Request {
      precondition(state == .initialized)
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
                  throw WebSocketError.invalidHTTPRequest
                case .complete(let message, unconsumed: _):
                  guard message.kind == .request else {
                    throw WebSocketError.invalidHTTPRequest
                  }
                  self.request = message
                  state = .pendingResponse
                  return Request(method: message.method!, target: message.target!,
                                 host: message.host, extraHeaders: message.extraHeaders,
                                 contentType: ContentType(from: message.contentType),
                                 content: message.content,
                                 upgradeRequested: message.upgrade.contains(.init("websocket")),
                                 subprotocols: message.webSocketProtocol)
              }
            default:
              break
          }
        }
        throw WebSocketError.invalidHTTPRequest
      } catch {
        state = .done
        throw error
      }
    }

    /// Sends an ordinary HTTP response to the client request.
    ///
    /// Note that ``WebSocketServer/Client/request()`` must have succeeded prior to calling this function. Upon return, even if there is an error, the connection
    /// will have been closed, and any further calls to the `Client` will result in runtime errors.
    ///
    /// - Parameter response: The response.
    /// - Throws: ``WebSocketError/invalidHTTPResponse`` if the response could not be encoded. This usually indicates that one or
    ///   more extra headers could not be expressed in the ISO-8859-1 (Latin 1) character set.
    public func respond(with response: Response) async throws {
      precondition(state == .pendingResponse)
      state = .sendingResponse
      var message = HTTPMessage(status: response.status, reason: response.status.description)
      if response.status.kind == .redirection, let location = response.location {
        message.location = location
      }
      message.extraHeaders = response.extraHeaders
      message.addConnection("close")
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
      defer {
        state = .done
        connection.close()
      }
      guard let data = message.encode() else {
        throw WebSocketError.invalidHTTPResponse
      }
      await connection.send(data: data)
    }

    /// Sends an ordinary HTTP response with a plain text body.
    ///
    /// Note that ``WebSocketServer/Client/request()`` must have succeeded prior to calling this function. Upon return,  the connection
    /// will have been closed, and any further calls to the `Client` will result in runtime errors.
    ///
    /// - Parameter status: The HTTP status code.
    /// - Parameter plainText: The response body.
    public func respond(with status: HTTPStatus, plainText text: String) async {
      var response = Response(with: status)
      response.contentType = .init(mediaType: "text/plain", charset: "utf-8")
      response.content = text.data(using: .utf8)
      // We know there aren't any funky extra headers in our response, so we can assume that this will always succeed.
      return try! await respond(with: response)
    }

    /// Sends an HTTP redirect response.
    ///
    /// Note that ``WebSocketServer/Client/request()`` must have succeeded prior to calling this function. Upon return,  the connection
    /// will have been closed, and any further calls to the `Client` will result in runtime errors.
    ///
    /// - Parameter status: The HTTP status code.
    /// - Parameter location: The target location.
    public func redirect(with status: HTTPStatus = .movedPermanently, to location: String) async {
      precondition(status.kind == .redirection)
      var response = Response(with: status)
      response.location = location
      return try! await respond(with: response)
    }

    /// Upgrades the connection to a WebSocket.
    ///
    /// Note that ``WebSocketServer/Client/request()`` must have succeeded prior to calling this function, and the resulting request must be
    /// a valid WebSocket upgrade request. If an error occurs,  an appropriate HTTP error response is sent, and the connection is closed. Whether this function
    /// succeeds or fails,  any further calls to the `Client` will result in runtime errors.
    /// - Parameter subprotocol: The selected subprotocol. If not `nil`, this must be one of the options from the request's
    ///   ``WebSocketServer/Request/subprotocols``.
    /// - Parameter extraHeaders: Additional headers to include with the HTTP response.
    /// - Parameter options: The options for the new WebSocket.
    /// - Returns: The new WebSocket ready to communicate with the client.
    /// - Throws: ``WebSocketError/invalidHTTPResponse`` if the response could not be encoded (usually because one or
    ///   more extra headers could not be expressed in the ISO-8859-1 (Latin 1) character set),``WebSocketError/upgradeRejected``
    ///   if the request is not a valid WebSocket upgrade request.
    public func upgrade(subprotocol: String? = nil,
                        extraHeaders: [String: String] = [:],
                        options: WebSocket.Options = WebSocket.Options()) async throws -> WebSocket {
      precondition(state == .pendingResponse)
      state = .sendingResponse
      let response = makeServerHandshakeResponse(to: request!, subprotocol: subprotocol, extraHeaders: extraHeaders)
      guard let data = response.encode() else {
        throw WebSocketError.invalidHTTPResponse
      }
      await connection.send(data: data)
      state = .done
      guard !response.status!.isError else {
        connection.close()
        throw WebSocketError.upgradeRejected
      }
      let handshakeResult = WebSocket.HandshakeResult(subprotocol: subprotocol, extraHeaders: request!.extraHeaders)
      return WebSocket(url: URL(string: request!.target!)!,
                       connection: connection,
                       handshakeResult: handshakeResult,
                       options: options)
    }
  }
}
