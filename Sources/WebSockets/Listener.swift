import Foundation
import Network

class Listener: AsyncSequence {
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

  // TODO: maybe this doesn't get WebSocket.Options?
  init(port: UInt16, tls: Bool, options: WebSocket.Options) {
    dispatchQueue = DispatchQueue(label: "WebSocket listener on port \(port)")
    stream = AsyncThrowingStream { continuation in
      self.continuation = continuation
    }

    let params = NWParameters(tls: tls ? NWProtocolTLS.Options() : nil, tcp: NWProtocolTCP.Options())
    params.allowLocalEndpointReuse = true
    params.includePeerToPeer = true

    do {
      listener = try NWListener(using: params, on: .init(rawValue: port)!)
      listener!.newConnectionHandler = { [weak self] connection in
        self?.continuation.yield(.connection(Connection(with: connection, options: options)))
      }
      listener!.stateUpdateHandler = { [weak self] state in
        self?.stateChanged(to: state)
      }
      listener!.start(queue: dispatchQueue)
    } catch {
      continuation.finish(throwing: WebSocket.ServerError.listenerFailed(reason: error.localizedDescription,
                                                                         underlyingError: error))
    }
  }

  deinit {
    print("* Listener deinit")
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
        continuation.finish(throwing: WebSocket.ServerError.listenerFailed(reason: error.localizedDescription,
                                                                           underlyingError: error))
      default:
        break
    }
  }
}
