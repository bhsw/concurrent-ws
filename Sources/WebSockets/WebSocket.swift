import Foundation

// TODO: server support
// TODO: basic authorization?
// TODO: linux support

/// A WebSocket endpoint class with a modern API based on [Swift Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html).
///
/// The implementation strives to be fully compliant with [RFC 6455](https://datatracker.ietf.org/doc/html/rfc6455).
///
/// Since `WebSocket` is an actor, its public interface is thread-safe.
///
public actor WebSocket {
  /// Options that can be set for a `WebSocket` instance.
  public struct Options {
    /// Zero or more subprotocols supported by the socket. If this list is not empty, the other endpoint must also support at least
    /// one of the given subprotocols for the connection to be established. Defaults to an empty list.
    public var subprotocols: [String] = []

    /// Whether the socket should automatically respond to incoming `ping` frames with matching `pong` frames. Defaults to `true`.
    public var automaticallyRespondToPings: Bool = true

    /// The maximum number of HTTP redirects that will be followed during the handshake. Defaults to `5`.
    public var maximumRedirects = 5

    /// The  number of seconds that the socket will wait for the connection to succeed before throwing an error. Defaults to `30`.
    public var openingHandshakeTimeout: TimeInterval = 30

    /// The  number of seconds that the socket will wait for the other endpoint to acknowledge a request to close the connection. Defaults to `30`.
    public var closingHandshakeTimeout: TimeInterval = 30

    /// Whether to enable TCP fast open. Defaults to `false`.
    public var enableFastOpen: Bool = false

    /// The maximum payload size, in bytes, of an incoming text or binary message. If this limit is exceeded, the connection is closed with a policy
    /// violation error. Defaults to `Int.max`
    public var maximumIncomingMessageSize: Int = Int.max

    /// The maximum number of incoming bytes handled during a single receive operation. Defaults to `32768`.
    public var receiveChunkSize: Int = 32768

    /// Additional headers to add to the initial HTTP request. The dictionary maps header names to associated values. Note that headers that are relied upon
    /// to complete the handshake  (such as `Sec-*` or `Upgrade`) are considered forbidden and will be ignored if included.
    public var extraHeaders: [String: String] = [:]

    /// Initializes a default set of WebSocket options.
    public init() {
    }
  }

  /// An event that has occurred on a `WebSocket`.
  public enum Event {
    /// Indicates that a connection to the remote endpoint was successful. This event is emitted exactly once and is always the first event emitted.
    case open(HandshakeResult)

    /// Indicates that a text message was received from the other endpoint.
    case text(String)

    /// Indicates that a textual message was received from the other endpoint.
    case binary(Data)

    /// Indicates that the connection has been closed. This event is emitted exactly once and is always the final event emitted.  The `wasClean` parameter
    /// will be `true` if the WebSocket closing handshake completed successfully, or `false` if an endpoint terminated the connection unilaterally.
    case close(code: CloseCode, reason: String, wasClean: Bool)

    /// Indicates that a `ping` frame has been received from the other endpoint.
    case ping(Data)

    /// Indicates that a `pong` frame has been received from the other endpoint.
    case pong(Data)

    /// Indicates that the network path used by the connection has ceased to be viable (`false`) or regained viability (`true`).
    case connectionViability(Bool)

    /// Indicates that a better network path has become available (`true`) or is no longer available (`false`). This is often a signal that, for example,
    /// wi-fi has become an option where a cellular connection is currently in use.
    case betterConnectionAvailable(Bool)
  }

  /// The current status of the connection.
  public enum ReadyState {
    /// The  socket has been initialized, but no attempt has been made yet to establish the connection.
    case initialized

    /// The socket is currently working to establish a connection to the other endpoint. This includes the handshakes for the TCP, TLS (if applicable), and
    /// WebSocket protocols.
    case connecting

    /// A successful connection was established.
    case open

    /// The connection is being closed. The socket remains in this state until it has received an acknowledgement from the other endpoint, or the
    /// timeout has been reached.
    case closing

    /// The connection is closed.
    case closed
  }

  /// The  status of the socket. Note that accessing this property outside of your event processing loop is a probably a TOCTOU (time-of-check to time-of-use)
  /// race condition, since the state may change between the time you request it and act on the result.
  public private(set) var readyState: ReadyState = .initialized

  /// The URL. This will be the same URL passed to the initializer unless a redirect has occurred. This property's value is subject to change until the `open`
  /// state is reached.
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
  private var parkedSends: [ParkedSend] = []
  private var redirectCount = 0
  private var handshakeTimerTask: Task<Void, Never>?
  private var openingHandshakeDidExpire = false
  private var handshakeResult: HandshakeResult?

  /// Initializes a new `WebSocket` instance.
  ///
  /// Note that the connection will not be attempted until a task requests the first event from the sequence.
  public init(url: URL, options: Options = .init()) {
    self.url = url
    self.options = options
    outputFramer = OutputFramer(forClient: true)
    inputFramer = InputFramer(forClient: true, maximumMessageSize: options.maximumIncomingMessageSize)
  }

  init(url: URL, connection: Connection, handshakeResult: HandshakeResult, options: Options) {
    self.url = url
    self.options = options
    self.handshakeResult = handshakeResult
    outputFramer = OutputFramer(forClient: false)
    inputFramer = InputFramer(forClient: false, maximumMessageSize: options.maximumIncomingMessageSize)
    // TODO connection.reconfigure()
    readyState = .connecting
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
  /// - Parameter data: Any arbitrary data to include with the frame. The WebSocket protocol limits the size of this data to 125 bytes.
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
  /// - Parameter data: Any arbitrary data to include with the frame. The WebSocket protocol limits the size of this data to 125 bytes.
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
  /// * If `connecting`, the underlying connection will be canceled, the socket will immediately enter the `closed` state, and the event sequence
  ///   will finish without producing any events.
  /// * If `open`, the socket will immediately enter the `closing` state, and a `close` frame will be sent to the other endpoint. Once a `close`
  ///   frame is received from the other endpoint, or if the configured `closingHandshakeTimeout` expires prior to receiving a response,
  ///   the underlying connection will be closed, and the socket will enter the `closed` state. In every case, a `close` event will be added to
  ///   the socket's event sequence as the final event.
  /// * If `closing` or `closed`, this function has no effect.
  ///
  /// - Parameters:
  ///   - code: The close code. Note that any restricted close codes are silently converted to `.normalClosure`.
  ///   - reason: The reason. The WebSocket protocol limits the reason to 123 UTF-8 code units. If this limit is exceeded, the reason will be truncated
  ///     to fit as many full Unicode code points as possible.
  public func close(with code: CloseCode = .normalClosure, reason: String = "") async {
    switch readyState {
      case .initialized:
        readyState = .closed
      case .connecting:
        readyState = .closed
        connection!.close()
      case .open:
        readyState = .closing
        pendingCloseCode = code.isRestricted ? .normalClosure : code
        pendingCloseReason = reason
        if (await sendNow(frame: .close(pendingCloseCode!, reason))) {
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
  /// - Throws: `HandshakeError` if an error occurs while the socket is in the `connecting` state. Errors are never thrown in any other state.
  public func next() async throws -> Event? {
    switch readyState {
      case .initialized:
        return try await connect()
      case .connecting:
        // We should only ever get here for server-side WebSockets.
        precondition(handshakeResult != nil)
        return .open(handshakeResult!)
      case .open, .closing:
        return await nextEvent()
      case .closed:
        return nil
    }
  }
}

// MARK: Private implementation

private extension WebSocket {
  /// A frame that was submitted to send prior to the socket entering the `open` state.
  struct ParkedSend {
    let frame: Frame
    let continuation: CheckedContinuation<Bool, Never>
  }

  /// Sends a frame or parks it for delivery once the connection enters the `open` state.
  /// - Parameter frame: The frame.
  /// - Returns: Whether the frame was accepted.
  func send(frame: Frame) async -> Bool {
    switch readyState {
      case .initialized, .connecting:
        return await withCheckedContinuation { continuation in
          parkedSends.append(.init(frame: frame, continuation: continuation))
        }
      case .open:
        return await sendNow(frame: frame)
      case .closing, .closed:
        return false
    }
  }

  /// Performs the opening HTTP handshake.
  /// - Returns: The `open` event, or `nil` if the connection was closed prior to the handshake completing.
  /// - Throws: `HandshakeError` if the handshake fails.
  func connect() async throws -> Event? {
    precondition(readyState == .initialized || readyState == .connecting)
    guard let scheme = url.scheme?.lowercased(), let host = url.host else {
      throw HandshakeError.invalidURL(url)
    }
    guard scheme == "ws" || scheme == "wss" else {
      throw HandshakeError.invalidURLScheme(scheme)
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
    let connectionOptions = Connection.Options(receiveChunkSize: options.receiveChunkSize,
                                               enableFastOpen: options.enableFastOpen)
    connection = Connection(host: host, port: port, tls: useTLS, options: connectionOptions)
    let handshake = ClientHandshake(options: options)
    do {
      for try await event in connection! {
        switch event {
          case .connect:
            try await connection!.send(data: handshake.makeRequest(url: url))
          case .receive(let data):
            switch try handshake.receive(data: data) {
              case .incomplete:
                continue
              case .ready(result: let result, unconsumed: let unconsumed):
                handshakeResult = result
                cancelHandshakeTimer()
                inputFramer.push(unconsumed)
                readyState = .open
                for parked in parkedSends {
                  let result = await sendNow(frame: parked.frame)
                  parked.continuation.resume(returning: result)
                }
                parkedSends.removeAll()
                return .open(result)
              case .redirect(let location):
                guard redirectCount < options.maximumRedirects else {
                  throw HandshakeError.maxRedirectsExceeded
                }
                guard let newURL = URL(string: location, relativeTo: url) else {
                  throw HandshakeError.invalidRedirectLocation(location)
                }
                redirectCount += 1
                connection!.close()
                connection = nil
                self.url = newURL
                return try await connect()
            }
          default:
            continue
        }
      }
      if openingHandshakeDidExpire {
        throw HandshakeError.timeout
      }
      throw HandshakeError.unexpectedDisconnect
    } catch let error as HandshakeError {
      cancelHandshakeTimer()
      let suppressError = readyState == .closed && !openingHandshakeDidExpire
      if readyState != .closed {
        connection!.close()
      }
      connection = nil
      readyState = .closed
      for parked in parkedSends {
        parked.continuation.resume(returning: false)
      }
      parkedSends.removeAll()
      if (suppressError) {
        return nil
      }
      throw error
    } catch {
      fatalError("Connection is only allowed to throw HandshakeError")
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
      return finishClose()
    } catch let error as HandshakeError {
      // The connection threw an error.
      pendingCloseReason = error.localizedDescription
      return finishClose()
    } catch {
      // This should never happen, since connections are only supposed to throw HandshakeErrors.
      fatalError("Connection in only allowed to throw HandshakeError")
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
          await sendNow(frame: .close(code, reason))
        }
        return finishClose()
      case .ping(let data):
        if (options.automaticallyRespondToPings) {
          await sendNow(frame: .pong(data))
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
    await sendNow(frame: .close(code, reason))
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

  /// Sends a frame through the output framer and directly to the underlying connection.
  /// - Returns: Whether the frame was successfully sent.
  @discardableResult
  func sendNow(frame: Frame) async -> Bool {
    precondition(readyState == .open || readyState == .closing)
    guard outputFramer.push(frame) else {
      return false
    }
    return await connection!.send(data: outputFramer.pop()!)
  }

  /// Cancels the handshake timer if it is running.
  func cancelHandshakeTimer() {
    if (handshakeTimerTask != nil) {
      handshakeTimerTask?.cancel()
      handshakeTimerTask = nil
    }
  }
}
