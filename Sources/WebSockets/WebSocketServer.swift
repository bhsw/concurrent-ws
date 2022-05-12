// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation

/// A simple HTTP 1.1 server that supports upgrading connections to WebSockets.
///
/// `WebSocketServer` is a an `AsyncSequence` that allows you to iterate over and react to events that occur on the server, such as incoming
/// HTTP requests and network status notifications. Each server should have a single, dedicated `Task` that processes events from that server.
/// However, the rest of the API, such as ``WebSocketServer/stop()`` is designed to be used from any task or thread.
///
/// The following is a minimal example that simply responds to any HTTP request with a diagnostic message:
///
/// ```swift
/// let server = WebSocketServer(on: 8080)
///   for try await event in server {
///     switch event {
///       case .ready:
///         print("Ready to accept requests")
///       case .request(let request):
///         await request.respond(with: .ok,
///           plainText: "\(request.method) on \(request.target)\n")
///       case .networkUnavailable:
///         print("The network is unavailable")
///     }
///   }
/// ```
///
/// See the `EchoServer` example in the source distribution for a more extensive demonstration of the API.
public actor WebSocketServer {
  /// Options that can be set for a `WebSocketServer` instance.
  public struct Options {
    /// The  number of seconds that the server will wait for an incoming connection to send an HTTP request before dropping the connection. Defaults to `30`.
    public var requestTimeout: TimeInterval = 30

    /// Initializes a default set of server options.
    public init() {
    }
  }

  /// An event that has occured on a `WebSocketServer`.
  public enum Event {
    /// Indicates that the server is ready to accept requests.
    case ready

    /// Indicates that no network is currently available on which to receive requests.
    case networkUnavailable

    /// Indicates that an HTTP request has been received
    case request(Request)
  }

  private let listener: Listener
  private let options: Options
  private let eventQueue = EventQueue<Event>()
  private var uncommittedConnections: [Connection] = []
  private var state: State = .initialized

  /// Initializes a new `WebSocketServer` that listens on the specified port.
  /// - Parameter port: The port. If `0`, an unused one will be assigned by the system.
  /// - Parameter options: Server options.
  public init(on port: UInt16 = 0, options: Options = Options()) {
    listener = Listener(port: port)
    self.options = options
  }

  /// The port on which the server accepts connections.
  ///
  /// If the server has been asked to assign an unused port, the value of this property will be `0` until the `ready` event has been emitted.
  public nonisolated var port: UInt16 {
    listener.port
  }

  /// Stops accepting new connections.
  ///
  /// No further events will be added to the queue, and the event iterator will return `nil` once the final event has been consumed.
  ///
  /// Incoming connections that have not been upgraded to websockets are closed without an HTTP response. Existing websockets are **not closed**
  /// by this function; it is up to the individual application to manage the lifespan of its websockets. There may still be `request` events in the queue
  /// after this function is called, and they can be handled as they normally would be, although the underlying connections will already be closed,
  /// and responses to those requests will be ignored.
  ///
  /// Note that it is not possible to restart a `WebSocketServer`.
  public func stop() {
    guard state == .started else {
      return
    }
    listener.stop()
    for connection in uncommittedConnections {
      connection.close()
    }
    uncommittedConnections.removeAll()
    state = .stopped
  }
}

// MARK: AsyncSequence conformance

extension WebSocketServer: AsyncSequence, AsyncIteratorProtocol {
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
    start()
    return try await eventQueue.pop()
  }
}

// MARK: Private implementation

extension WebSocketServer {
  private enum State {
    case initialized
    case started
    case stopped
  }

  private func start() {
    guard state == .initialized else {
      return
    }
    state = .started
    Task {
      do {
        for try await event in listener {
          switch event {
            case .ready:
              eventQueue.push(.ready)
            case .networkUnavailable:
              eventQueue.push(.networkUnavailable)
            case .connection(let connection):
              accept(connection: connection)
          }
        }
        eventQueue.finish()
      } catch {
        eventQueue.finish(throwing: error)
      }
    }
  }

  private func accept(connection: Connection) {
    uncommittedConnections.append(connection)
    Task {
      let timer = Task {
        if (try? await Task.sleep(nanoseconds: UInt64(options.requestTimeout) * 1_000_000_000)) != nil {
          connection.close()
        }
      }
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
                  timer.cancel()
                  let request = Request(from: message, connection: connection, server: self)
                  eventQueue.push(.request(request))
                  return
              }
            default:
              break
          }
        }
        throw WebSocketError.invalidHTTPRequest
      } catch {
        timer.cancel()
        removeUncommitted(connection: connection)
        connection.close()
      }
    }
  }

  @discardableResult
  func removeUncommitted(connection: Connection) -> Bool {
    if let index = uncommittedConnections.firstIndex(where: { $0 === connection }) {
      uncommittedConnections.remove(at: index)
      return true
    }
    return false
  }
}

// MARK: Request

extension WebSocketServer {
  /// Information about an HTTP request.
  public class Request {
    /// The HTTP method.
    public var method: HTTPMethod {
      message.method!
    }

    /// The request target (e.g. `/api/status`)
    public var target: String {
      message.target!
    }

    /// The value of the `Host` header, or `nil` if the request did not include that header.
    public var host: String? {
      message.host
    }

    /// Additional headers included with the request.
    ///
    /// The dictionary maps header names to associated values.
    public var extraHeaders: [String: String] {
      message.extraHeaders
    }

    /// The content type associated with the body of the request, or `nil` if unspecified.
    public var contentType: ContentType? {
      ContentType(from: message.contentType)
    }

    /// The body of the request, or `nil` if the request does not include a body.
    public var content: Data? {
      message.content
    }

    /// Whether the client is requesting an upgrade to the WebSocket protocol.
    public var upgradeRequested: Bool {
      message.upgrade.contains(websocketProtocol)
    }

    /// The list of WebSocket subprotocols that the client would like to use, ordered from most preferred to least preferred.
    public var subprotocols: [String] {
      message.webSocketProtocol
    }

    /// The client's IP address.
    public var clientAddress: String {
      connection.host!
    }

    /// The client's port.
    public var clientPort: UInt16 {
      connection.port!
    }

    /// The client's IP address and port.
    public var clientEndpoint: String {
      "\(clientAddress):\(clientPort)"
    }

    private let message: HTTPMessage
    private let connection: Connection
    private weak var server: WebSocketServer?

    init(from message: HTTPMessage, connection: Connection, server: WebSocketServer) {
      self.message = message
      self.connection = connection
      self.server = server
    }

    deinit {
      // Ensure that we don't leak the  connection if a request gets dropped without sending a
      // response or upgrading to a WebSocket.
      if let server = server {
        let connection = connection
        Task.detached {
          if (await server.removeUncommitted(connection: connection)) {
            connection.close()
          }
        }
      }
    }

    /// Sends an ordinary HTTP response to the request.
    ///
    /// If a response has already been sent, or the connection has been upgraded to a WebSocket, this function has no effect.
    /// - Parameter response: The response.
    public func respond(with response: Response) async {
      guard let server = server, await server.removeUncommitted(connection: connection) else {
        // An attempt was already made to respond to the request.
        return
      }
      self.server = nil             // Not strictly necessary but eliminates work in the deinitializer
      var message = HTTPMessage(status: response.status, reason: response.status.description)
      if response.status.kind == .redirection, let location = response.location {
        message.location = location
      }
      message.extraHeaders = response.extraHeaders
      message.addConnection("close")
      if response.status.allowsContent, let content = response.content {
        message.contentLength = content.count
        if method != .head {
          message.content = content
        }
        if let contentType = response.contentType {
          var token = ParameterizedToken(token: contentType.mediaType)
          token.set(parameter: "charset", to: contentType.charset)
          message.contentType = token
        }
      }
      await connection.send(data: message.encode())
      connection.close()
    }

    /// Sends an ordinary HTTP response with a plain text body.
    ///
    /// If a response has already been sent, or the connection has been upgraded to a WebSocket, this function has no effect.
    ///
    /// - Parameter status: The HTTP status code.
    /// - Parameter plainText: The response body.
    public func respond(with status: HTTPStatus, plainText text: String) async {
      var response = Response(with: status)
      response.contentType = .init(mediaType: "text/plain", charset: "utf-8")
      response.content = text.data(using: .utf8)
      // We know there aren't any funky extra headers in our response, so we can assume that this will always succeed.
      return await respond(with: response)
    }

    /// Sends an HTTP redirect response.
    ///
    /// If a response has already been sent, or the connection has been upgraded to a WebSocket, this function has no effect.
    ///
    /// - Parameter status: The HTTP status code.
    /// - Parameter location: The target location.
    public func redirect(with status: HTTPStatus = .movedPermanently, to location: String) async {
      precondition(status.kind == .redirection)
      var response = Response(with: status)
      response.location = location
      return await respond(with: response)
    }

    /// Upgrades the request's connection to a WebSocket.
    ///
    /// The request must be a valid WebSocket upgrade request. If it is not, an appropriate HTTP error response will be sent, and the
    /// connection will be closed.
    /// - Parameter subprotocol: The selected subprotocol. If not `nil`, this must be one of the options from the request's
    ///   ``WebSocketServer/Request/subprotocols``.
    /// - Parameter extraHeaders: Additional headers to include with the HTTP response.
    /// - Parameter options: The options for the new WebSocket.
    /// - Returns: The new WebSocket ready to communicate with the client, or `nil` if the upgrade could not be performed.
    public func upgrade(subprotocol: String? = nil,
                        extraHeaders: [String: String] = [:],
                        options: WebSocket.Options = WebSocket.Options()) async -> WebSocket? {
      guard let server = server, await server.removeUncommitted(connection: connection) else {
        // An attempt was already made to respond to the request.
        return nil
      }
      self.server = nil             // Not strictly necessary but eliminates work in the deinitializer

      let compression = options.enableCompression ? firstValidCompressionOffer(from: message)?.respond() : nil
      let response = makeServerHandshakeResponse(to: message, subprotocol: subprotocol, compression: compression,
                                                 extraHeaders: extraHeaders)
      guard await connection.send(data: response.encode()),
            !response.status!.isError else {
        connection.close()
        return nil
      }
      let handshakeResult = WebSocket.HandshakeResult(subprotocol: subprotocol,
                                                      compressionAvailable: compression != nil,
                                                      extraHeaders: message.extraHeaders)
      return WebSocket(url: URL(string: message.target!)!,
                       connection: connection,
                       handshakeResult: handshakeResult,
                       compression: compression,
                       options: options)
    }
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
}
