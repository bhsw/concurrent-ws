import Foundation
import Network

class Listener: AsyncSequence {
  enum Event {
    case connection(Connection)
  }

  typealias StreamType = AsyncThrowingStream<Event, Error>
  typealias AsyncIterator = StreamType.Iterator
  typealias Element = Event

  private let dispatchQueue: DispatchQueue
  private var stream: StreamType!
  private var streamContinuation: StreamType.Continuation!
  private var listener: NWListener?

  init(port: UInt16, tls: Bool, options: WebSocket.Options) {
    dispatchQueue = DispatchQueue(label: "WebSocket listener on port \(port)")
    stream = AsyncThrowingStream { continuation in
      streamContinuation = continuation
    }

    let params = NWParameters(tls: tls ? NWProtocolTLS.Options() : nil, tcp: NWProtocolTCP.Options())
    params.allowLocalEndpointReuse = true
    params.includePeerToPeer = true

    do {
      listener = try NWListener(using: params, on: .init(rawValue: port)!)
      listener!.newConnectionHandler = { [weak self] connection in
        self?.streamContinuation.yield(.connection(Connection(with: connection, options: options)))
      }
      listener!.start(queue: dispatchQueue)
    } catch {
      // TODO: we might want to finish with an error here, but it's not really a handshake error
      streamContinuation.finish()
    }
  }

  deinit {
    print("* Listener deinit")
  }

  func stop() {
    listener?.cancel()
    streamContinuation.finish()
  }

  func makeAsyncIterator() -> AsyncIterator {
    return stream.makeAsyncIterator()
  }
}
