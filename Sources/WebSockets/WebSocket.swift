// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation

/// A WebSocket endpoint class with a modern API based on [Swift Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html).
///
/// This implementation supports both client and server WebSockets based on [RFC 6455](https://datatracker.ietf.org/doc/html/rfc6455). See
/// ``WebSocketServer`` for server functionality.
///
/// `WebSocket` is a an `AsyncSequence` that allows you to iterate over and react to events that occur on the connection, such as text or binary data
/// received from the other endpoint. Each websocket should have a single, dedicated `Task` that processes events from that websocket. However, the rest of
/// the API, such as ``WebSocket/send(text:compress:)`` and ``WebSocket/close(with:reason:)`` is designed to be used from any task or thread.
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
    /// If this limit is exceeded, the connection is closed with a policy violation error. This happens as soon as the frame header has been
    /// received, so the endpoint does not need to waste bandwidth accepting the entire message.
    ///
    /// Note that when compression is used, this limit applies to the size of the *compressed* payload, which is the only size known at the start
    /// of frame processing. To apply the limit to the decompressed payload would require receiving the entire payload and then decompressing it.
    public var maximumIncomingMessagePayloadSize: Int = Int.max

    /// The maximum number of incoming bytes handled during a single receive operation. Defaults to `32768`.
    public var receiveChunkSize: Int = 32768

    /// Additional headers to add to the initial HTTP request. Defaults to `[:]`.
    ///
    /// The dictionary maps header names to associated values. Note that headers that are relied upon to complete the handshake
    /// (such as `Sec-*` or `Upgrade`) are considered forbidden and will be ignored if included.
    ///
    /// This option does not apply to server-side sockets created by ``WebSocketServer``.
    public var extraHeaders: [String: String] = [:]

    /// Whether to enable the `permessage-deflate` compression extension. Defaults to `true`.
    ///
    /// Note that setting this property to `true` does not guarantee that compression will actually be available, as both endpoints need to
    /// support the extension and agree to use it.
    public var enableCompression: Bool = true

    /// The range of textual message sizes, in UTF-8 code units, to be compressed when the `auto` compression mode is used.
    /// Defaults to a minimum of 8 code units with no maximum.
    ///
    /// Note that this range applies only to messages *sent* by the local endpoint. The remote endpoint controls its own use of compression.
    public var textAutoCompressionRange = 8..<Int.max

    /// The range of binary message sizes, in bytes, to be compressed when the `auto` compression mode is used.
    /// Defaults to a minimum of 8 bytes with no maximum.
    ///
    /// Note that this range applies only to messages *sent* by the local endpoint. The remote endpoint controls its own use of compression.
    public var binaryAutoCompressionRange = 8..<Int.max

    /// Initializes a default set of WebSocket options.
    public init() {
    }
  }

  /// An event that has occurred on a `WebSocket`.
  public enum Event : Equatable {
    /// Indicates that a connection to the remote endpoint was successful.
    ///
    /// This event is emitted exactly once and is always the first event emitted.
    case open(HandshakeResult)

    /// Indicates that a textual message was received from the other endpoint.
    case text(String)

    /// Indicates that a binary data message was received from the other endpoint.
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
  public struct HandshakeResult : Equatable {
    /// The subprotocol that was negotiated by the endpoints, or `nil` if no subprotocol is in effect.
    public let subprotocol: String?

    /// Whether messages may be compressed.
    ///
    /// This property will only be `true` if both endpoints agreed to use the `permessage-deflate` Websocket extension.
    public let compressionAvailable: Bool

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

    /// The response body if one was provided.
    public let content: Data?
  }

  /// The compression mode to use when sending a message to the other endpoint.
  public enum CompressionMode {
    /// The message will be compressed if the endpoints agreed to use compression during the opening handshake, and the size of the message
    /// falls within the range defined by the `textAutoCompressionRange` or `binaryAutoCompressionRange` option, depending on
    /// the type of message.
    case auto

    /// The message is guaranteed not to be compressed.
    case never

    /// The message will be compressed as long as the endpoints agreed to use compression during the opening handshake.
    case always

    func accepts(size: Int, range: Range<Int>) -> Bool {
      switch self {
        case .auto:
          return range.contains(size)
        case .never:
          return false
        case .always:
          return true
      }
    }
  }

  /// Statistics about data sent or received by a WebSocket.
  ///
  /// Note that these counters will wrap if they overflow. The fact that they're stored as 64-bit  integers makes that unlikely, but in very extreme use cases, it
  /// might be necessary to sample and reset the statistics at regular intervals if accurate metrics are required.
  public struct Statistics: Equatable {
    /// The number of control frames transferred.
    ///
    /// This total includes `ping`, `pong`, and `close` frames.
    public var controlFrameCount: Int64 = 0

    /// The number of textual messages transferred.
    ///
    /// Note that this total includes both uncompressed and compressed messages.
    public var textMessageCount: Int64 = 0

    /// The number of binary messages transferred.
    ///
    /// Note that this total includes both uncompressed and compressed messages.
    public var binaryMessageCount: Int64 = 0

    /// The total number of UTF-8 code units transferred as part of textual messages.
    ///
    /// Note that this total includes both uncompressed and compressed messages.
    public var textBytesTransferred: Int64 = 0

    /// The total number of bytes transferred as part of binary messages.
    ///
    /// Note that this total includes the payload of both uncompressed and compressed messages.
    public var binaryBytesTransferred: Int64 = 0

    /// The number of compressed textual messages transferred.
    public var compressedTextMessageCount: Int64 = 0

    /// The total number of bytes transferred by compressed textual messages.
    public var compressedTextBytesTransferred: Int64 = 0

    /// The total number of bytes saved by compressing textual messages.
    ///
    /// This counter may be negative if compression is actually *increasing* the aggregate payload size. This would be an unexpected outcome for
    /// text but would indicate that compression should probably be disabled for that particular use caes.
    public var compressedTextBytesSaved: Int64 = 0

    /// The number of compressed binary messages transferred.
    public var compressedBinaryMessageCount: Int64 = 0

    /// The total number of bytes transferred by compressed binary messages.
    public var compressedBinaryBytesTransferred: Int64 = 0

    /// The total number of bytes saved by compressing binary messages.
    ///
    /// This counter may be negative if compression is actually *increasing* the aggregate payload size. This often indicates that pre-compressed data,
    /// such as an image or video, is being transferred without disabling WebSocket compression for at least those types of messages.
    public var compressedBinaryBytesSaved: Int64 = 0

    // Initializes all counters to 0
    public init() {
    }
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
  private var handshakeTimerTask: Task<Void, Never>?
  private var openingHandshakeDidExpire = false
  private var pendingOpen: Result<Event?, Error>?
  private var parkedUntilOpen: [CheckedContinuation<Void, Never>] = []

  /// Initializes a new `WebSocket` instance.
  ///
  /// Note that the connection will not be attempted until a message is sent or a task requests the first event from the sequence.
  ///
  /// - Parameter url: The URL of the endpoint to which to connect. The scheme must be `ws` or `wss`.
  /// - Parameter options: The options.
  public init(url: URL, options: Options = .init()) {
    self.url = url
    self.options = options
    outputFramer = OutputFramer(forClient: true)
    inputFramer = InputFramer(forClient: true, maximumMessageSize: options.maximumIncomingMessagePayloadSize)
  }

  /// Initializes a server-side `WebSocket`.
  ///
  /// This internal API is used by ``WebSocketServer``.
  ///
  /// - Parameter url: The URL requested by the client.
  /// - Parameter connection: The connection to the client. The server WebSocket handshake must already be complete.
  /// - Parameter handshakeResult: The result of the handshake.
  /// - Parameter compression: The negotiated compression offer.
  /// - Parameter options: The options.
  init(url: URL, connection: Connection, handshakeResult: HandshakeResult, compression: DeflateParameters?, options: Options) {
    self.url = url
    self.options = options
    self.connection = connection
    outputFramer = OutputFramer(forClient: false, compression: compression)
    inputFramer = InputFramer(forClient: false, maximumMessageSize: options.maximumIncomingMessagePayloadSize, compression: compression)
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
  /// - Parameter compress: The compression mode for the message.
  /// - Returns: `true` if the text was successfully submitted for transmission, or `false` if an error occurred or the connection was closed.
  @discardableResult
  public func send(text: String, compress: CompressionMode = .auto) async -> Bool {
    return await send(frame: .text(text),
                      compress: compress.accepts(size: text.utf8.count, range: options.textAutoCompressionRange))
  }

  /// Sends a binary message to the other endpoint.
  ///
  /// See the discussion for ``WebSocket/send(text:compress:)`` for more information about the semantics of this operation.
  /// - Parameter data: The data to send.
  /// - Parameter compress: The compression mode for the message.
  /// - Returns: `true` if the data was successfully submitted for transmission, or `false` if an error occurred or the connection was closed.
  @discardableResult
  public func send(data: Data, compress: CompressionMode = .auto) async -> Bool {
    return await send(frame: .binary(data),
                      compress: compress.accepts(size: data.count, range: options.binaryAutoCompressionRange))
  }

  /// Sends a `ping` frame to the other endpoint.
  ///
  /// See the discussion for ``WebSocket/send(text:compress:)`` for more information about the semantics of this operation.
  /// - Parameter data: Any arbitrary data to include with the frame. The WebSocket protocol limits the size of this data to 125 bytes. If the
  ///   specified data exceeds the limit, only the first 125 bytes are sent.
  /// - Returns: Whether the frame was successfully submitted for transmission.
  @discardableResult
  public func ping(data: Data) async -> Bool {
    return await send(frame: .ping(data))
  }

  /// Sends a `pong` frame to the other endpoint.
  ///
  /// See the discussion for ``WebSocket/send(text:compress:)`` for more information about the semantics of this operation.
  /// - Parameter data: Any arbitrary data to include with the frame. The WebSocket protocol limits the size of this data to 125 bytes. If the
  ///   specified data exceeds the limit, only the first 125 bytes are sent.
  /// - Returns: Whether the frame was successfully submitted for transmission.
  @discardableResult
  public func pong(data: Data) async -> Bool {
    return await send(frame: .pong(data))
  }

  /// Closes the socket.
  ///
  /// The behavior of this function depends on the ``WebSocket/readyState-swift.property`` of the socket:
  ///
  /// * If `initialized`, the socket will immediately enter the `closed` state, and the event sequence will finish without producing any events.
  /// * If `connecting`, the task will suspend until the opening handshake completes. If the handshake is successful, processing will resume
  ///   according to the logic discussed for the `open` state below. If the handshake fails, the underlying connection will be canceled, the
  ///   socket will enter the `closed` state, and the event sequence will finish with an error.
  /// * If `open`, the socket will immediately enter the `closing` state, and a `close` frame will be sent to the other endpoint. Once a `close`
  ///   frame is received from the other endpoint, or if the configured `closingHandshakeTimeout` expires prior to receiving a response,
  ///   the underlying connection will be closed, and the socket will enter the `closed` state. In every case, a `close` event will be added to
  ///   the socket's event sequence as the final event.
  /// * If `closing` or `closed`, this function has no effect.
  ///
  /// It is important to keep in mind that this function does not wait for the socket to finish closing. That effect can be achieved by calling this function
  /// and then `await`ing the result of the `Task` that is processing events emitted by the socket.
  /// - Parameters:
  ///   - code: The close code. If `nil`, a `close` frame with no payload will be sent to the remote endpoint. Note that any restricted close codes
  ///     are silently converted to `nil`.
  ///   - reason: The reason. The WebSocket protocol limits the reason to 123 UTF-8 code units. If this limit is exceeded, the reason will be truncated
  ///     to fit as many full Unicode code points as possible. This parameter is ignored if the close code is `nil`.
  public func close(with code: CloseCode? = .normalClosure, reason: String = "") async {
    switch readyState {
      case .initialized:
        readyState = .closed
      case .connecting:
        await finishOpeningHandshake()
        await close(with: code, reason: reason)
      case .open:
        readyState = .closing
        if await connection!.send(multiple: outputFramer.encode(.close((code?.isRestricted ?? false) ? nil : code, reason))) {
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

  /// Samples and optionally resets  input and output statistics.
  /// - Parameter reset: Whether to reset all counters to 0 after taking the sample.
  /// - Returns: The input and output statistics just prior to the reset.
  ///
  public func sampleStatistics(reset: Bool = false) -> (Statistics, Statistics) {
    let inputStatistics = inputFramer.statistics, outputStatistics = outputFramer.statistics
    if (reset) {
      inputFramer.resetStatistics()
      outputFramer.resetStatistics()
    }
    return (input: inputStatistics, output: outputStatistics)
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
  /// - Parameter compress: Whether to compress the frame (if possible).
  /// - Returns: Whether the frame was accepted.
  func send(frame: Frame, compress: Bool = false) async -> Bool {
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
        return await send(frame: frame, compress: compress)
      case .connecting:
        await finishOpeningHandshake()
        return await send(frame: frame, compress: compress)
      case .open:
        return await connection!.send(multiple: outputFramer.encode(frame, compress: compress))
      case .closing, .closed:
        return false
    }
  }

  /// Performs the opening HTTP handshake.
  /// - Returns: The `open` event.
  /// - Throws: ``WebSocketError`` if the handshake fails.
  func connect() async throws -> Event {
    precondition(readyState == .initialized)
    readyState = .connecting
    handshakeTimerTask = Task(priority: TaskPriority.low) {
      guard (try? await Task.sleep(nanoseconds: UInt64(options.openingHandshakeTimeout * 1_000_000_000))) != nil else {
        return
      }
      openingHandshakeDidExpire = true
      connection?.close()
      readyState = .closed
    }
    var redirectCount = 0
    do {
    redirect: while true {
      guard let scheme = url.scheme?.lowercased(), let host = url.host else {
        throw WebSocketError.invalidURL(url)
      }
      guard scheme == "ws" || scheme == "wss" else {
        throw WebSocketError.invalidURLScheme(scheme)
      }
      let useTLS = scheme == "wss"
      let port = UInt16(url.port ?? (useTLS ? 443 : 80))
      connection = Connection(host: host, port: port, tls: useTLS, options: options)
      let handshake = ClientHandshake(options: options)
      for try await event in connection! {
        switch event {
          case .connect:
            await connection!.send(data: handshake.makeRequest(url: url).encode())
          case .receive(let data):
            switch try handshake.receive(data: data) {
              case .incomplete:
                continue
              case .ready(result: let result, unconsumed: let unconsumed):
                cancelHandshakeTimer()
                if let compression = handshake.compression {
                  inputFramer.enableCompression(offer: compression)
                  outputFramer.enableCompression(offer: compression)
                }
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
                self.url = newURL.absoluteURL
                continue redirect
            }
          default:
            continue
        }
      }
      // The `AsyncThrowingStream` used by Connection finishes the stream (yielding `nil`) if the Task is
      // canceled. However, we want an error to be thrown in this instance so that it's not confused with
      // the server simply dropping the connection.
      if Task.isCancelled {
        throw WebSocketError.canceled
      }
      if openingHandshakeDidExpire {
        throw WebSocketError.timeout
      }
      throw WebSocketError.unexpectedDisconnect
    }
    } catch let error as WebSocketError {
      cancelHandshakeTimer()
      connection?.close()
      connection = nil
      readyState = .closed
      resumeTasksWaitingForOpen()
      throw error
    } catch {
      fatalError("Connection is only allowed to throw WebSocketError")
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
      return finishClose(with: .abnormalClosure, reason: "The remote endpoint disconnected unexpectedly")
    } catch let error as WebSocketError {
      // The connection threw an error.
      readyState = .closing
      return finishClose(with: .abnormalClosure, reason: error.localizedDescription)
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
          readyState = .closing
          await connection!.send(multiple: outputFramer.encode(.close(code, reason)))
        }
        return finishClose(with: code ?? .noStatusReceived, reason: reason)
      case .ping(let data):
        if (options.automaticallyRespondToPings) {
          await connection!.send(multiple: outputFramer.encode(.pong(data)))
        }
        return .ping(data)
      case .pong(let data):
        return .pong(data)
      case .protocolError(let error):
        return await abortConnection(with: .protocolError, reason: error.debugDescription)
      case .messageTooBig:
        return await abortConnection(with: .messageTooBig, reason: "Maximum message size exceeded")
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
    precondition(readyState == .open || readyState == .closing)
    readyState = .closing
    await connection!.send(multiple: outputFramer.encode(.close(code, reason)))
    return finishClose(with: code, reason: reason)
  }

  /// Finishes closing the connection.
  /// - Parameter code - The close code.
  /// - Parameter reason - The close reason.
  /// - Returns: The `close` event.
  func finishClose(with code: CloseCode, reason: String) -> Event {
    precondition(readyState == .closing)
    cancelHandshakeTimer()
    connection!.close()
    connection = nil
    readyState = .closed
    return .close(code: code, reason: reason, wasClean: didSendCloseFrame && didReceiveCloseFrame)
  }

  /// Cancels the handshake timer if it is running.
  func cancelHandshakeTimer() {
    if (handshakeTimerTask != nil) {
      handshakeTimerTask?.cancel()
      handshakeTimerTask = nil
    }
  }
}
