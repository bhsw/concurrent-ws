import Foundation

extension WebSocket {
  public enum HTTPMethod: Equatable, RawRepresentable {
    case get
    case head
    case post
    case put
    case delete
    case connect
    case options
    case trace
    case patch
    case other(String)

    public init(rawValue: String) {
      let name = rawValue.uppercased()
      switch name {
        case "GET":
          self = .get
        case "HEAD":
          self = .head
        case "POST":
          self = .post
        case "PUT":
          self = .put
        case "DELETE":
          self = .delete
        case "CONNECT":
          self = .connect
        case "OPTIONS":
          self = .options
        case "TRACE":
          self = .trace
        case "PATCH":
          self = .patch
        default:
          self = .other(name)
      }
    }

    public var rawValue: String {
      switch self {
        case .get:
          return "GET"
        case .head:
          return "HEAD"
        case .post:
          return "POST"
        case .put:
          return "PUT"
        case .delete:
          return "DELETE"
        case .connect:
          return "CONNECT"
        case .options:
          return "OPTIONS"
        case .trace:
          return "TRACE"
        case .patch:
          return "PATCH"
        case .other(let value):
          return value
      }
    }
  }
}

internal typealias HTTPMethod = WebSocket.HTTPMethod
