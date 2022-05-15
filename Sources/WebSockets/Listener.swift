// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation
import Network

final class Listener: AsyncSequence {
  enum Event {
    case ready
    case networkUnavailable
    case connection(Connection)
  }

  typealias StreamType = AsyncThrowingStream<Event, Error>
  typealias AsyncIterator = StreamType.Iterator
  typealias Element = Event

  private let dispatchQueue: DispatchQueue
  private var stream: StreamType!
  private var continuation: StreamType.Continuation!
  private var listener: NWListener?

  init(port: UInt16, identity: SecIdentity? = nil) {
    dispatchQueue = DispatchQueue(label: "WebSocket listener on port \(port)")
    stream = AsyncThrowingStream { continuation in
      self.continuation = continuation
    }

    let params: NWParameters
    if let secIdentity = identity, let identity = sec_identity_create(secIdentity) {
      let tls = NWProtocolTLS.Options()
      sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
      params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    } else {
      params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
    }
    params.allowLocalEndpointReuse = true
    params.includePeerToPeer = true

    do {
      listener = try NWListener(using: params, on: .init(rawValue: port)!)
      listener!.newConnectionHandler = { [weak self] connection in
        self?.continuation.yield(.connection(Connection(with: connection)))
      }
      listener!.stateUpdateHandler = { [weak self] state in
        self?.stateChanged(to: state)
      }
      listener!.start(queue: dispatchQueue)
    } catch {
      continuation.finish(throwing: WebSocketError.listenerFailed(reason: error.localizedDescription,
                                                                  underlyingError: error))
    }
  }

  var port: UInt16 {
    listener?.port?.rawValue ?? 0
  }

  func stop() {
    listener?.cancel()
    continuation.finish()
  }

  func makeAsyncIterator() -> AsyncIterator {
    return stream.makeAsyncIterator()
  }

  private func stateChanged(to state: NWListener.State) {
    switch state {
      case .ready:
        continuation.yield(.ready)
      case .waiting(_):
        continuation.yield(.networkUnavailable)
      case .failed(let error):
        continuation.finish(throwing: WebSocketError.listenerFailed(reason: error.localizedDescription,
                                                                    underlyingError: error))
      default:
        break
    }
  }
}
