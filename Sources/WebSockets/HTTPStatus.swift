import Foundation

extension WebSocket {
  /// An HTTP 1.1 status code, as defined in [RFC 7231](https://www.rfc-editor.org/rfc/rfc7231#section-6) section 6.
  public enum HTTPStatus: Equatable, RawRepresentable {
    /// Continue (`100`)
    case `continue`

    /// Switching Protocols (`101`)
    case switchingProtocols

    /// OK (`200`)
    case ok

    /// Created (`201`)
    case created

    /// Accepted (`202`)
    case accepted

    /// Non-Authoritative Information (`203`)
    case nonAuthoritativeInformation

    /// No Content (`204`)
    case noContent

    /// Reset Content (`205`)
    case resetContent

    /// Partial Content (`206`)
    case partialContent

    /// Multiple Choices (`300`)
    case multipleChoices

    /// Moved Permanently (`301`)
    case movedPermanently

    /// Found (`302`)
    case found

    /// See Other (`303`)
    case seeOther

    /// Not Modified (`304`)
    case notModified

    /// Use Proxy (`305`)
    case useProxy

    /// Temporary Redirect (`307`)
    case temporaryRedirect

    /// Bad Request (`400`)
    case badRequest

    /// Unauthorized (`401`)
    case unauthorized

    /// Payment Required (`402`)
    case paymentRequired

    /// Forbidden (`403`)
    case forbidden

    /// Not Found (`404`)
    case notFound

    /// Method Not Allowed (`405`)
    case methodNotAllowed

    /// Not Acceptable (`406`)
    case notAcceptable

    /// Proxy Authentication Required (`407`)
    case proxyAuthenticationRequired

    /// Request Timeout (`408`)
    case requestTimeout

    /// Conflict (`409`)
    case conflict

    /// Gone (`410`)
    case gone

    /// Length Required (`411`)
    case lengthRequired

    /// Precondition Failed (`412`)
    case preconditionFailed

    /// Payload Too Large (`413`)
    case payloadTooLarge

    /// URI Too Long (`414`)
    case uriTooLong

    /// Unsupported Media Type (`415`)
    case unsupportedMediaType

    /// Range Not Satisfiable (`416`)
    case rangeNotSatisfiable

    /// Expectation Failed (`417`)
    case expectationFailed

    /// Upgrade Required (`426`)
    case upgradeRequired

    /// Internal Server Error (`500`)
    case internalServerError

    /// Not Implemented (`501`)
    case notImplemented

    /// Bad Gateway (`502`)
    case badGateway

    /// Service Unavailable (`503`)
    case serviceUnavailable

    /// Gateway Timeout (`504`)
    case gatewayTimeout

    /// HTTP Version Not Supported (`505`)
    case httpVersionNotSupported

    /// A custom status code
    case other(Int)

    /// Initializes an `HTTPStatus` from its numeric equivalent.
    /// - Parameter rawValue: The integer status code.
    public init(rawValue: Int) {
      switch rawValue {
        case 100:
          self = .continue
        case 101:
          self = .switchingProtocols

        case 200:
          self = .ok
        case 201:
          self = .created
        case 202:
          self = .accepted
        case 203:
          self = .nonAuthoritativeInformation
        case 204:
          self = .noContent
        case 205:
          self = .resetContent
        case 206:
          self = .partialContent

        case 300:
          self = .multipleChoices
        case 301:
          self = .movedPermanently
        case 302:
          self = .found
        case 303:
          self = .seeOther
        case 304:
          self = .notModified
        case 305:
          self = .useProxy
        case 307:
          self = .temporaryRedirect

        case 400:
          self = .badRequest
        case 401:
          self = .unauthorized
        case 402:
          self = .paymentRequired
        case 403:
          self = .forbidden
        case 404:
          self = .notFound
        case 405:
          self = .methodNotAllowed
        case 406:
          self = .notAcceptable
        case 407:
          self = .proxyAuthenticationRequired
        case 408:
          self = .requestTimeout
        case 409:
          self = .conflict
        case 410:
          self = .gone
        case 411:
          self = .lengthRequired
        case 412:
          self = .preconditionFailed
        case 413:
          self = .payloadTooLarge
        case 414:
          self = .uriTooLong
        case 415:
          self = .unsupportedMediaType
        case 416:
          self = .rangeNotSatisfiable
        case 417:
          self = .expectationFailed
        case 426:
          self = .upgradeRequired

        case 500:
          self = .internalServerError
        case 501:
          self = .notImplemented
        case 502:
          self = .badGateway
        case 503:
          self = .serviceUnavailable
        case 504:
          self = .gatewayTimeout
        case 505:
          self = .httpVersionNotSupported

        default:
          self = .other(rawValue)
      }
    }

    /// The integer value of the `HTTPStatus`.
    public var rawValue: Int {
      switch self {
        case .continue:
          return 100
        case .switchingProtocols:
          return 101

        case .ok:
          return 200
        case .created:
          return 201
        case .accepted:
          return 202
        case .nonAuthoritativeInformation:
          return 203
        case .noContent:
          return 204
        case .resetContent:
          return 205
        case .partialContent:
          return 206

        case .multipleChoices:
          return 300
        case .movedPermanently:
          return 301
        case .found:
          return 302
        case .seeOther:
          return 303
        case .notModified:
          return 304
        case .useProxy:
          return 305
        case .temporaryRedirect:
          return 307

        case .badRequest:
          return 400
        case .unauthorized:
          return 401
        case .paymentRequired:
          return 402
        case .forbidden:
          return 403
        case .notFound:
          return 404
        case .methodNotAllowed:
          return 405
        case .notAcceptable:
          return 406
        case .proxyAuthenticationRequired:
          return 407
        case .requestTimeout:
          return 408
        case .conflict:
          return 409
        case .gone:
          return 410
        case .lengthRequired:
          return 411
        case .preconditionFailed:
          return 412
        case .payloadTooLarge:
          return 413
        case .uriTooLong:
          return 414
        case .unsupportedMediaType:
          return 415
        case .rangeNotSatisfiable:
          return 416
        case .expectationFailed:
          return 417
        case .upgradeRequired:
          return 426

        case .internalServerError:
          return 500
        case .notImplemented:
          return 501
        case .badGateway:
          return 502
        case .serviceUnavailable:
          return 503
        case .gatewayTimeout:
          return 504
        case .httpVersionNotSupported:
          return 505

        case .other(let value):
          return value
      }
    }

    /// The corresponding *reason phrase* as defined in RFC 7231 section 6.1.
    public var description: String {
      switch self {
        case .continue:
          return "Continue"
        case .switchingProtocols:
          return "Switching Protocols"
        case .ok:
          return "OK"

        case .created:
          return "Created"
        case .accepted:
          return "Accepted"
        case .nonAuthoritativeInformation:
          return "Non-Authoritative Information"
        case .noContent:
          return "No Content"
        case .resetContent:
          return "Reset Content"
        case .partialContent:
          return "Partial Content"

        case .multipleChoices:
          return "Multiple Choices"
        case .movedPermanently:
          return "Moved Permanently"
        case .found:
          return "Found"
        case .seeOther:
          return "See Other"
        case .notModified:
          return "Not Modified"
        case .useProxy:
          return "Use Proxy"
        case .temporaryRedirect:
          return "Temporary Redirect"

        case .badRequest:
          return "Bad Request"
        case .unauthorized:
          return "Unauthorized"
        case .paymentRequired:
          return "Payment Required"
        case .forbidden:
          return "Forbidden"
        case .notFound:
          return "Not Found"
        case .methodNotAllowed:
          return "Method Not Allowed"
        case .notAcceptable:
          return "Not Acceptable"
        case .proxyAuthenticationRequired:
          return "Proxy Authentication Required"
        case .requestTimeout:
          return "Request Timeout"
        case .conflict:
          return "Conflict"
        case .gone:
          return "Gone"
        case .lengthRequired:
          return "Length Required"
        case .preconditionFailed:
          return "Precondition Failed"
        case .payloadTooLarge:
          return "Payload Too Large"
        case .uriTooLong:
          return "URI Too Long"
        case .unsupportedMediaType:
          return "Unsupported Media Type"
        case .rangeNotSatisfiable:
          return "Range Not Satisfiable"
        case .expectationFailed:
          return "Expectation Failed"
        case .upgradeRequired:
          return "Upgrade Required"

        case .internalServerError:
          return "Internal Server Error"
        case .notImplemented:
          return "Not Implemented"
        case .badGateway:
          return "Bad Gateway"
        case .serviceUnavailable:
          return "Service Unavailable"
        case .gatewayTimeout:
          return "Gateway Timeout"
        case .httpVersionNotSupported:
          return "HTTP Version Not Supported"
        case .other(let value):
          return String(value)
      }
    }

    /// The class of the status code.
    public enum Kind: Equatable {
      /// Informational status codes (100-199)
      case informational

      /// Status codes indicating success (200-299)
      case successful

      /// Redirection status codes (300-399)
      case redirection

      /// Status codes indicating a client error (400-499)
      case clientError

      /// Status codes indicating a server error (500-599)
      case serverError

      /// Status codes that fall outside of the defined classes.
      case invalid
    }

    /// The class of the status code.
    public var kind: Kind {
      switch rawValue {
        case 100...199:
          return .informational
        case 200...299:
          return .successful
        case 300...399:
          return .redirection
        case 400...499:
          return .clientError
        case 500...599:
          return .serverError
        default:
          return .invalid
      }
    }

    /// Whether the status code indicates a client or server error.
    public var isError: Bool {
      switch kind {
        case .clientError, .serverError:
          return true
        default:
          return false
      }
    }

    /// Whether the status code allows a response body.
    public var allowsContent: Bool {
      switch self {
        case .noContent, .notModified:
          return false
        default:
          return  kind != .informational
      }
    }
  }
}

internal typealias HTTPStatus = WebSocket.HTTPStatus
