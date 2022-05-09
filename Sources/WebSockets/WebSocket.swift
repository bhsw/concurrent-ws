// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation

// TODO: basic authorization?
// TODO: task cancellation behavior while iterating over events

/// A WebSocket endpoint class with a modern API based on [Swift Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html).
///
/// This implementation supports both client and server WebSockets based on [RFC 6455](https://datatracker.ietf.org/doc/html/rfc6455). See
/// ``WebSocketServer`` for server functionality.
///
/// `WebSocket` is a an `AsyncSequence` that allows you to iterate over and react to events that occur on the connection, such as text or binary data
/// received from the other endpoint. Each websocket should have a single, dedicated `Task` that processes events from that websocket. However, the rest of
/// the API, such as ``WebSocket/send(text:)`` and ``WebSocket/close(with:reason:)`` is designed to be used from any task or thread.
///
/// The following is a simple example:
///
/// ```swift
/// let socket = WebSocket(url: URL("wss://echo.websocket.events")!)
/// do {
///   for try await event in socket {
///     switch event {
///       case .open(_):
///         print("Successfully opened the WebSocket")
///         await socket.send(text: "Hello, world")
///       case .text(let str):
///         print("Received text: \(str)")
///       case .close(code: let code, reason: _, wasClean: _):
///         print("Closed with code: \(code)")
///       default:
///         print("Miscellaneous event: \(event)")
///     }
///   }
/// } catch {
///   print("An error occurred connecting to the remote endpoint: \(error)")
/// }
/// ```
public actor WebSocket {
  /// Options that can be set for a `WebSocket` instance.
  public struct Options {
    /// Zero or more subprotocols supported by the client, ordered from most preferred to least preferred. Defaults to `[]`.
    ///
    /// The server may accept one of the listed protocols, or it may decline to accept any of them. The only thing that is prohibited is for the server
    /// to assert a subprotocol that was not offered by the client.
    ///
    /// This option does not apply to server-side sockets created by ``WebSocketServer``
    public var subprotocols: [String] = []

    /// Whether the socket should automatically respond to incoming `ping` frames with matching `pong` frames. Defaults to `true`.
    public var automaticallyRespondToPings: Bool = true

    /// The maximum number of HTTP redirects that will be followed during the handshake. Defaults to `5`.
    ///
    /// This option does not apply to server-side sockets created by ``WebSocketServer``
    public var maximumRedirects = 5

    /// The  number of seconds that the socket will wait for the connection to succeed before throwing an error. Defaults to `30`.
    ///
    /// This option does not apply to server-side sockets created by ```WebSocketServer```.
    public var openingHandshakeTimeout: TimeInterval = 30

    /// The  number of seconds that the socket will wait for the other endpoint to acknowledge a request to close the connection. Defaults to `30`.
    public var closingHandshakeTimeout: TimeInterval = 30

    /// Whether to enable TCP fast open. Defaults to `false`.
    ///
    /// This option does not apply to server-side sockets created by ``WebSocketServer``.
    public var enableFastOpen: Bool = false

    /// The maximum payload size, in bytes, of an incoming text or binary message. Defaults to `Int.max`.
    ///
    /// If this limit is exceeded, the connection is closed with a policy violation error.
    public var maximumIncomingMessageSize: Int = Int.max

    /// The maximum number of incoming bytes handled during a single receive operation. Defaults to `32768`.
    public var receiveChunkSize: Int = 32768

    /// Additional headers to add to the initial HTTP request. Defaults to `[:]`.
    ///
    /// The dictionary maps header names to associated values. Note that headers that are relied upon to complete the handshake
    /// (such as `Sec-*` or `Upgrade`) are considered forbidden and will be ignored if included.
    ///
    /// This option does not apply to server-side sockets created by ``WebSocketServer``.
    public var extraHeaders: [String: String] = [:]

    /// Initializes a default set of WebSocket options.
    public init() {
    }
  }

  /// An event that has occurred on a `WebSocket`.
  public enum Event {
    /// Indicates that a connection to the remote endpoint was successful.
    ///
    /// This event is emitted exactly once and is always the first event emitted.
    case open(HandshakeResult)

    /// Indicates that a text message was received from the other endpoint.
    case text(String)

    /// Indicates that a textual message was received from the other endpoint.
    case binary(Data)

    /// Indicates that the connection has been closed.
    ///
    /// This event is emitted exactly once and is always the final event emitted.  The `wasClean` parameter will be `true` if the WebSocket
    /// closing handshake completed successfully, or `false` if an endpoint terminated the connection unilaterally.
    case close(code: CloseCode, reason: String, wasClean: Bool)

    /// Indicates that a `ping` frame has been received from the other endpoint.
    case ping(Data)

    /// Indicates that a `pong` frame has been received from the other endpoint.
    case pong(Data)

    /// Indicates that the network path used by the connection has ceased to be viable (`false`) or regained viability (`true`).
    case connectionViability(Bool)

    /// Indicates that a better network path has become available (`true`) or is no longer available (`false`).
    ///
    /// This is often a signal that, for example, wi-fi has become an option where a cellular connection is currently in use.
    case betterConnectionAvailable(Bool)
  }

  /// The current status of the connection.
  public enum ReadyState {
    /// The  socket has been initialized, but no attempt has been made yet to establish the connection.
    case initialized

    /// The socket is currently working to establish a connection to the other endpoint.
    ///
    /// This includes the handshakes for the TCP, TLS (if applicable), and WebSocket protocols.
    case connecting

    /// A successful connection was established.
    case open

    /// The connection is being closed.
    ///
    /// The socket remains in this state until it has received an acknowledgement from the other endpoint, or the timeout has been reached.
    case closing

    /// The connection is closed.
    case closed
  }

  /// The result of a successful WebSocket opening handshake.
  public struct HandshakeResult {
    /// The subprotocol that was negotiated by the endpoints, or `nil` if no subprotocol is in effect.
    public let subprotocol: String?

    /// Any HTTP headers received from the other endpoint that were not pertinent to the WebSocket handshake.
    ///
    /// The dictionary maps lowercase header names to associated values.
    ///
    /// For client-side sockets, the headers are from the server's *response* to the initial HTTP request.
    /// For server-side sockets created by ``WebSocketServer``, the headers are from the initial HTTP *request* received from the client.
    public let extraHeaders: [String: String]
  }

  /// The result of a failed WebSocket opening handshake.
  public struct FailedHandshakeResult {
    /// The HTTP status code.
    public let status: HTTPStatus

    /// The HTTP reason string.
    public let reason: String

    /// Any headers received in the HTTP response that were not pertinent to the WebSocket handshake. The dictionary maps lowercase header names to associated values.
    public let extraHeaders: [String: String]

    /// The content type of the response body, if any.
    public let contentType: ContentType?

    // The response body if one was provided.
    public let content: Data?
  }

  /// The  status of the socket.
  ///
  /// Note that accessing this property outside of your event processing loop is a probably a TOCTOU (time-of-check to time-of-use)
  /// race condition, since the state may change between the time you request it and act on the result.
  public private(set) var readyState: ReadyState = .initialized

  /// The URL.
  ///
  /// For client-side sockets, this will be the same URL passed to the initializer unless a redirect has occurred. This property's value is subject to change
  /// until the `open` state is reached.
  ///
  /// For sockets created by ``WebSocketServer``, the value of this property wil be a relative URL matching the resource path requested by
  /// the client in the opening handshake (e.g. `/api/events`).
  public private(set) var url: URL

  /// The options that were passed to the initializer.
  public let options: Options

  private var connection: Connection?
  private var outputFramer: OutputFramer
  private var inputFramer: InputFramer
  private var didSendCloseFrame = false
  private var didReceiveCloseFrame = false
  private var pendingCloseCode: CloseCode?
  private var pendingCloseReason: String?
  private var handshakeTimerTask: Task<Void, Never>?
  private var openingHandshakeDidExpire = false
  private var pendingOpen: Result<Event?, Error>?
  private var parkedUntilOpen: [CheckedContinuation<Void, Never>] = []

  /// Initializes a new `WebSocket` instance.
  ///
  /// Note that the connection will not be attempted until a task requests the first event from the sequence.
  ///
  /// - Parameter url: The URL of the endpoint to which to connect. The scheme must be `ws` or `wss`.
  /// - Parameter options: The options.
  public init(url: URL, options: Options = .init()) {
    self.url = url
    self.options = options
    outputFramer = OutputFramer(forClient: true)
    inputFramer = InputFramer(forClient: true, maximumMessageSize: options.maximumIncomingMessageSize)
  }

  /// Initializes a server-side `WebSocket`.
  ///
  /// This internal API is used by ``WebSocketServer``.
  ///
  /// - Parameter url: The URL requested by the client.
  /// - Parameter connection: The connection to the client. The server WebSocket handshake must already be complete.
  /// - Parameter handshakeResult: The result of the handshake.
  /// - Parameter options: The options.
  init(url: URL, connection: Connection, handshakeResult: HandshakeResult, options: Options) {
    self.url = url
    self.options = options
    self.connection = connection
    outputFramer = OutputFramer(forClient: false)
    inputFramer = InputFramer(forClient: false, maximumMessageSize: options.maximumIncomingMessageSize)
    connection.reconfigure(with: options)
    pendingOpen = .success(.open(handshakeResult))
    readyState = .open
  }

  /// Sends a textual message to the other endpoint.
  ///
  /// This asynchronous function returns `true` as soon as the message is successfully submitted to the network stack on the local host. It is important to
  /// understand that this does not indicate that the message made it through the network to the other endpoint. This function can return `false` for
  /// several different reasons:
  ///
  /// * The connection has reached the `closing` or `closed` state.
  /// * An error occurred while submitting the message. Any such error is always fatal to the connection and is therefore reported via a `close` event
  ///   to the event reader.
  ///
  /// If this function is called before a connection has been established, the message will be queued and sent when the socket reaches the `open` state.
  /// - Parameter text: The text to send.
  /// - Returns: `true` if the text was successfully submitted for transmission, or `false` if an error occurred or the connection was closed.
  @discardableResult
  public func send(text: String) async -> Bool {
    return await send(frame: .text(text))
  }

  /// Sends a binary message to the other endpoint.
  ///
  /// This asynchronous function returns `true` as soon as the message is successfully submitted to the network stack on the local host. It is important to
  /// understand that this does not indicate that the message made it through the network to the other endpoint. This function can return `false` for
  /// several different reasons:
  ///
  /// * The connection has reached the `closing` or `closed` state.
  /// * An error occurred while submitting the message. Any such error is always fatal to the connection and is therefore reported via a `close` event
  ///   to the event reader.
  ///
  /// If this function is called before a connection has been established, the message will be queued and sent when the socket reaches the `open` state.
  /// - Parameter data: The data to send.
  /// - Returns: `true` if the data was successfully submitted for transmission, or `false` if an error occurred or the connection was closed.
  @discardableResult
  public func send(data: Data) async -> Bool {
    return await send(frame: .binary(data))
  }

  /// Sends a `ping` frame to the other endpoint.
  ///
  /// This asynchronous function returns `true` as soon as the frame is successfully submitted to the network stack on the local host. It is important to
  /// understand that this does not indicate that the frame made it through the network to the other endpoint. This function can return `false` for
  /// several different reasons:
  ///
  /// * The connection has reached the `closing` or `closed` state.
  /// * The given `data` exceeds the maximum length allowed.
  /// * An error occurred while submitting the frame. Any such error is always fatal to the connection and is therefore reported via a `close` event
  ///   to the event reader.
  ///
  /// If this function is called before a connection has been established, the frame will be queued and sent when the socket reaches the `open` state.
  /// - Parameter data: Any arbitrary data to include with the frame. The WebSocket protocol limits the size of this data to 125 bytes. If the
  ///   specified data exceeds the limit, only the first 125 bytes are sent.
  /// - Returns: Whether the frame was successfully submitted for transmission.
  @discardableResult
  public func ping(data: Data) async -> Bool {
    return await send(frame: .ping(data))
  }

  /// Sends a `pong` frame to the other endpoint.
  ///
  /// This asynchronous function returns `true` as soon as the frame is successfully submitted to the network stack on the local host. It is important to
  /// understand that this does not indicate that the frame made it through the network to the other endpoint. This function can return `false` for
  /// several different reasons:
  ///
  /// * The connection has reached the `closing` or `closed` state.
  /// * The given `data` exceeds the maximum length allowed.
  /// * An error occurred while submitting the frame. Any such error is always fatal to the connection and is therefore reported via a `close` event
  ///   to the event reader.
  ///
  /// If this function is called before a connection has been established, the frame will be queued and sent when the socket reaches the `open` state.
  /// - Parameter data: Any arbitrary data to include with the frame. The WebSocket protocol limits the size of this data to 125 bytes. If the
  ///   specified data exceeds the limit, only the first 125 bytes are sent.
  /// - Returns: Whether the frame was successfully submitted for transmission.
  @discardableResult
  public func pong(data: Data) async -> Bool {
    return await send(frame: .pong(data))
  }

  /// Closes the socket.
  ///
  /// The behavior of this function depends on the ready state of the socket:
  ///
  /// * If `initialized`, the socket will immediately enter the `closed` state, and the event sequence will finish without producing any events.
  /// * If `connecting`, the task will suspend until the opening handshake completes. If the handshake is successful, processing will resume
  ///   according to the logic discussed for the `open` state below. If the handshake fails, the underlying connection will be canceled, the
  ///   socket will enter the `closed`state, and the event sequence will finish with an error.
  /// * If `open`, the socket will immediately enter the `closing` state, and a `close` frame will be sent to the other endpoint. Once a `close`
  ///   frame is received from the other endpoint, or if the configured `closingHandshakeTimeout` expires prior to receiving a response,
  ///   the underlying connection will be closed, and the socket will enter the `closed` state. In every case, a `close` event will be added to
  ///   the socket's event sequence as the final event.
  /// * If `closing` or `closed`, this function has no effect.
  ///
  /// It is important to keep in mind that this function does not wait for the socket to finish closing. That effect can be achieved by calling this function
  /// and then `await`ing the result of the `Task` that is processing events emitted by the socket.
  /// - Parameters:
  ///   - code: The close code. Note that any restricted close codes are silently converted to `.normalClosure`.
  ///   - reason: The reason. The WebSocket protocol limits the reason to 123 UTF-8 code units. If this limit is exceeded, the reason will be truncated
  ///     to fit as many full Unicode code points as possible.
  public func close(with code: CloseCode = .normalClosure, reason: String = "") async {
    switch readyState {
      case .initialized:
        readyState = .closed
      case .connecting:
        await finishOpeningHandshake()
        await close(with: code, reason: reason)
      case .open:
        readyState = .closing
        pendingCloseCode = code.isRestricted ? .normalClosure : code
        pendingCloseReason = reason
        if await connection!.send(data: outputFramer.encode(.close(pendingCloseCode!, reason))) {
          didSendCloseFrame = true
        }
        handshakeTimerTask = Task(priority: TaskPriority.low) {
          do {
            try await Task.sleep(nanoseconds: UInt64(options.closingHandshakeTimeout * 1_000_000_000))
            connection?.close()
          } catch {
          }
        }
      case .closing, .closed:
        break
    }
  }
}

// MARK: AsyncSequence conformance

extension WebSocket : AsyncSequence, AsyncIteratorProtocol {
  public typealias Element = Event

  /// Gets the asynchronous iterator that can be used to loop over events emitted by the socket.
  /// - Returns: The iterator.
  public nonisolated func makeAsyncIterator() -> WebSocket {
    return self
  }

  /// Gets the next available event.
  /// - Returns: The event, or `nil` if the socket has entered the `closed` state, and no further events will be emitted.
  /// - Throws: ``WebSocketError`` if an error occurs while the socket is in the `connecting` state. Errors are never thrown in any other state.
  public func next() async throws -> Event? {
    if let result = pendingOpen {
      pendingOpen = nil
      switch result {
        case .success(let event):
          return event
        case .failure(let error):
          throw error
      }
    }
    switch readyState {
      case .initialized:
        return try await connect()
      case .connecting:
        // If we get here, it indicates that the application called `send()` on a different task before we started
        // iterating over events. We therefore have to suspend until the opening handshake triggered by that send
        // is complete.
        await finishOpeningHandshake()
        return try await next()
      case .open, .closing:
        return await nextEvent()
      case .closed:
        return nil
    }
  }
}

// MARK: Private implementation

private extension WebSocket {
  /// Sends a frame or parks it for delivery once the connection enters the `open` state.
  /// - Parameter frame: The frame.
  /// - Returns: Whether the frame was accepted.
  func send(frame: Frame) async -> Bool {
    switch readyState {
      case .initialized:
        // This is the first send request, and the application hasn't started consuming events yet, which means we're
        // responsible for performing the connect and opening handshake. First, however, reserve our spot in line
        // in case another write happens when this task suspends during the handshake.
        async let result: Void = await finishOpeningHandshake()
        do {
          pendingOpen = .success(try await connect())
        } catch {
          pendingOpen = .failure(error)
        }
        await result
        return await send(frame: frame)
      case .connecting:
        await finishOpeningHandshake()
        return await send(frame: frame)
      case .open:
        return await connection!.send(data: outputFramer.encode(frame))
      case .closing, .closed:
        return false
    }
  }

  /// Performs the opening HTTP handshake.
  /// - Returns: The `open` event, or `nil` if the connection was closed prior to the handshake completing.
  /// - Throws: ``WebSocketError`` if the handshake fails.
  func connect() async throws -> Event? {
    precondition(readyState == .initialized)
    var redirectCount = 0
  redirect: while true {
      guard let scheme = url.scheme?.lowercased(), let host = url.host else {
        readyState = .closed
        resumeTasksWaitingForOpen()
        throw WebSocketError.invalidURL(url)
      }
      guard scheme == "ws" || scheme == "wss" else {
        readyState = .closed
        resumeTasksWaitingForOpen()
        throw WebSocketError.invalidURLScheme(scheme)
      }

      readyState = .connecting
      if (handshakeTimerTask == nil) {
        // When a redirect has occured, the handshake timer will already be running.
        handshakeTimerTask = Task(priority: TaskPriority.low) {
          do {
            try await Task.sleep(nanoseconds: UInt64(options.openingHandshakeTimeout * 1_000_000_000))
            openingHandshakeDidExpire = true
            connection?.close()
            readyState = .closed
          } catch {
          }
        }
      }

      let useTLS = scheme == "wss"
      let port = UInt16(url.port ?? (useTLS ? 443 : 80))
      connection = Connection(host: host, port: port, tls: useTLS, options: options)
      let handshake = ClientHandshake(options: options)
      do {
        for try await event in connection! {
          switch event {
            case .connect:
              await connection!.send(data: handshake.makeRequest(url: url))
            case .receive(let data):
              switch try handshake.receive(data: data) {
                case .incomplete:
                  continue
                case .ready(result: let result, unconsumed: let unconsumed):
                  cancelHandshakeTimer()
                  inputFramer.push(unconsumed)
                  readyState = .open
                  resumeTasksWaitingForOpen()
                  return .open(result)
                case .redirect(let location):
                  guard redirectCount < options.maximumRedirects else {
                    throw WebSocketError.maximumRedirectsExceeded
                  }
                  guard let newURL = URL(string: location, relativeTo: url) else {
                    throw WebSocketError.invalidRedirectLocation(location)
                  }
                  redirectCount += 1
                  connection!.close()
                  connection = nil
                  self.url = newURL
                  continue redirect
              }
            default:
              continue
          }
        }
        if openingHandshakeDidExpire {
          throw WebSocketError.timeout
        }
        throw WebSocketError.unexpectedDisconnect
      } catch let error as WebSocketError {
        cancelHandshakeTimer()
        let suppressError = readyState == .closed && !openingHandshakeDidExpire
        if readyState != .closed {
          connection!.close()
        }
        connection = nil
        readyState = .closed
        resumeTasksWaitingForOpen()
        if (suppressError) {
          return nil
        }
        throw error
      } catch {
        fatalError("Connection is only allowed to throw WebSocketError")
      }
    }
  }

  /// Services the underlying connection and returns the next event.
  /// - Returns: The event.
  func nextEvent() async -> Event? {
    precondition(readyState == .open || readyState == .closing)
    do {
      if let event = await checkForInputFrame() {
        return event
      }
      for try await event in connection! {
        switch event {
          case .receive(let data):
            guard let data = data else {
              break
            }
            inputFramer.push(data)
            if let event = await checkForInputFrame() {
              return event
            }
          case .viability(let value):
            return .connectionViability(value)
          case .betterPathAvailable(let value):
            return .betterConnectionAvailable(value)
          case .connect:
            // This has by definition already happened, so we can ignore it here.
            break
        }
      }
      // The server disconnected without sending a close frame.
      readyState = .closing
      return finishClose()
    } catch let error as WebSocketError {
      // The connection threw an error.
      pendingCloseReason = error.localizedDescription
      readyState = .closing
      return finishClose()
    } catch {
      // This should never happen, since connections are only supposed to throw WebSocketErrors.
      fatalError("Connection in only allowed to throw WebSocketError")
    }
  }

  /// Gets the next frame from the input framer.
  /// - Returns: The frame, or `nil` if no frame is currently available.
  func checkForInputFrame() async -> Event? {
    guard let frame = inputFramer.pop() else {
      return nil
    }
    switch frame {
      case .text(let text):
        return .text(text)
      case .binary(let data):
        return .binary(data)
      case .close(let code, let reason):
        didReceiveCloseFrame = true
        if (!didSendCloseFrame) {
          pendingCloseCode = code;
          pendingCloseReason = reason
          readyState = .closing
          await connection!.send(data: outputFramer.encode(.close(code, reason)))
        }
        return finishClose()
      case .ping(let data):
        if (options.automaticallyRespondToPings) {
          await connection!.send(data: outputFramer.encode(.pong(data)))
        }
        return .ping(data)
      case .pong(let data):
        return .pong(data)
      case .protocolError(let error):
        return await abortConnection(with: .protocolError, reason: error.debugDescription)
      case .policyViolation(let error):
        return await abortConnection(with: .policyViolation, reason: error.debugDescription)
    }
  }

  /// Suspends the current task until the opening handshake has completed.
  func finishOpeningHandshake() async {
    guard readyState == .initialized || readyState == .connecting else {
      return
    }
    return await withCheckedContinuation { continuation in
      parkedUntilOpen.append(continuation)
    }
  }

  /// Resumes tasks that are waiting for the opening handshake to complete.
  func resumeTasksWaitingForOpen() {
    precondition(readyState != .initialized && readyState != .connecting)
    for continuation in parkedUntilOpen {
      continuation.resume()
    }
    parkedUntilOpen.removeAll()
  }

  /// Terminates the connection without performing a closing handshake.
  /// - Parameters:
  ///   - code: The close code.
  ///   - reason: The reason.
  /// - Returns: The `close` event.
  func abortConnection(with code: CloseCode, reason: String) async -> Event {
    precondition(readyState == .open)
    pendingCloseCode = code
    pendingCloseReason = reason
    readyState = .closing
    await connection!.send(data: outputFramer.encode(.close(code, reason)))
    return finishClose()
  }

  /// Finishes closing the connection.
  /// - Returns: The `close` event.
  func finishClose() -> Event {
    precondition(readyState == .closing)
    cancelHandshakeTimer()
    connection!.close()
    connection = nil
    readyState = .closed
    return .close(code: pendingCloseCode ?? .abnormalClosure,
                  reason: pendingCloseReason ?? "The endpoint disconnected unexpectedly",
                  wasClean: didSendCloseFrame && didReceiveCloseFrame)
  }

  /// Cancels the handshake timer if it is running.
  func cancelHandshakeTimer() {
    if (handshakeTimerTask != nil) {
      handshakeTimerTask?.cancel()
      handshakeTimerTask = nil
    }
  }
}
