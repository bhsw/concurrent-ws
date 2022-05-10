// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation
import Network

/// A TCP/IP connection, with or without TLS.
///
/// This internal class exists for two reasons:
/// * To isolate code that uses older conventions than tasks/async/await to a relatively small part of the library.
/// * To provide a consistent API on top of different lower level networking libraries.
final class Connection: AsyncSequence {
  enum Event {
    /// Indicates that a successful connection was made to the other endpoint.
    case connect

    /// Indicates that data were received from the other endpoint. If `nil`, the other endpoint closed the connection.
    case receive(Data?)

    /// Indiciates a change in the viability of the connection.
    case viability(Bool)

    /// Indicates a change in the availability of a better network path.
    case betterPathAvailable(Bool)
  }

  typealias StreamType = AsyncThrowingStream<Event, Error>
  typealias AsyncIterator = StreamType.Iterator
  typealias Element = Event

  private let dispatchQueue: DispatchQueue
  private var receiveChunkSize: Int
  private var stream: StreamType!
  private var continuation: StreamType.Continuation!
  private var connection: NWConnection

  init(with connection: NWConnection, options: WebSocket.Options = .init()) {
    let endpoint = connection.endpoint
    dispatchQueue = DispatchQueue(label: "WebSocket \(endpoint)")
    receiveChunkSize = options.receiveChunkSize

    self.connection = connection

    connection.stateUpdateHandler = { [weak self] state in
      self?.connectionStateChanged(to: state)
    }
    connection.viabilityUpdateHandler = { [weak self] value in
      self?.continuation.yield(.viability(value))
    }
    connection.betterPathUpdateHandler = { [weak self] value in
      self?.continuation.yield(.betterPathAvailable(value))
    }

    connection.start(queue: dispatchQueue)

    stream = AsyncThrowingStream { continuation in
      self.continuation = continuation
    }
  }

  convenience init(host: String, port: UInt16, tls: Bool, options: WebSocket.Options = .init()) {
    let tcp = NWProtocolTCP.Options()
    tcp.enableFastOpen = options.enableFastOpen

    let params = NWParameters(tls: tls ? NWProtocolTLS.Options() : nil, tcp: tcp)
    params.allowLocalEndpointReuse = true
    params.includePeerToPeer = true

    let connection = NWConnection(host: .init(host), port: .init(rawValue: UInt16(port))!, using: params)
    self.init(with: connection, options: options)
  }

  var host: String? {
    switch connection.endpoint {
      case .hostPort(let host, _):
        return String(describing: host)
      default:
        return nil
    }
  }

  var port: UInt16? {
    switch connection.endpoint {
      case .hostPort(_, let port):
        return port.rawValue
      default:
        return nil
    }
  }

  @discardableResult
  func send(data: Data) async -> Bool {
    return await withCheckedContinuation { continuation in
      dispatchQueue.async { [self] in
        connection.send(content: data, completion: .contentProcessed { error in
          if error != nil {
            continuation.resume(returning: false)
          } else {
            continuation.resume(returning: true)
          }
        })
      }
    }
  }

  func close() {
    connection.cancel()
    continuation.finish()
  }

  func makeAsyncIterator() -> AsyncIterator {
    return stream.makeAsyncIterator()
  }

  func reconfigure(with options: WebSocket.Options) {
    dispatchQueue.async { [weak self] in
      self?.receiveChunkSize = options.receiveChunkSize
    }
  }

  private func connectionStateChanged(to state: NWConnection.State) {
    switch (state) {
      case .waiting(let error):
        finish(throwing: error)
      case .ready:
        continuation.yield(.connect)
        receive()
      case .failed(let error):
        finish(throwing: error)
      default:
        break
    }
  }

  private func receive() {
    dispatchPrecondition(condition: .onQueue(dispatchQueue))
    connection.receive(minimumIncompleteLength: 1, maximumLength: receiveChunkSize) { [self] data, _, isComplete, error in
      if let data = data {
        continuation.yield(.receive(data))
      }
      if (isComplete) {
        continuation.yield(.receive(nil))
        continuation.finish()
        return
      }
      if let error = error {
        finish(throwing: error)
        return
      }
      receive()
    }
  }

  private func finish(throwing error: NWError) {
    continuation.finish(throwing: connectionError(from: error))
  }

  private func connectionError(from error: NWError) -> WebSocketError {
    switch error {
      case .posix(let code):
        let posixError = POSIXError(code)
        return .connectionFailed(reason: posixError.localizedDescription, underlyingError: error)
      case .dns(_):
        return .hostLookupFailed(reason: error.localizedDescription, underlyingError: error)
      case .tls(_):
        return .tlsFailed(reason: error.localizedDescription, underlyingError: error)
      @unknown default:
        return .connectionFailed(reason: error.localizedDescription, underlyingError: error)
    }
  }
}
