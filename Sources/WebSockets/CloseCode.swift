// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation

extension WebSocket {
  /// WebSocket close codes as defined by [RFC 6455](https://datatracker.ietf.org/doc/html/rfc6455) section 7.4.1.
  public enum CloseCode : Equatable {
    /// A normal closure (`1000`).
    case normalClosure

    /// An endpoint is "going away" (`1001`).
    case goingAway

    /// An endpoint is terminating the connection due to a protocol error (`1002`).
    case protocolError

    /// An endpoint is terminating the connection because it received a type of data it cannot accept (`1003`).
    case unsupportedData

    /// A restricted code that indicates that no close code was specified (`1005`).
    case noStatusReceived

    /// A restricted code that indicates that the connection was terminated without a successful closing handshake (`1006`).
    case abnormalClosure

    /// An endpoint is terminating the connection because it has received data within a message that was not consistent with the type of the message (`1007`).
    case invalidFramePayloadData

    /// An endpoint is terminating the connection because it received a message that violates its policy (`1008`).
    case policyViolation

    /// An endpoint is terminating the connection because it received a message that is too big for it to process (`1009`).
    case messageTooBig

    /// The client is terminating the  connection because the server failed to negotiate one or more extensions (`1010`).
    case mandatoryExtensionMissing

    /// The server is terminating the connection because it encountered an unexpected error (`1011`).
    case internalServerError

    /// A restricted code that indicates that the TLS handshake could not be completed (`1015`).
    case tlsHandshakeFailure

    /// Codes registered to libraries, frameworks, and applications, in the range of `3000` to `3999` (inclusive).
    case applicationCode(UInt16)

    /// Codes reserved for private, unregistered use, in the range of `4000` to `4999` (inclusive).
    case privateCode(UInt16)

    /// A code that is out of compliance with the ranges defined in the RFC.
    case invalidCode(UInt16)

    /// Initializes a `CloseCode` from a raw value.
    /// - Parameter rawValue: The value
    public init(rawValue: UInt16) {
      switch rawValue {
        case 1000:
          self = .normalClosure
        case 1001:
          self = .goingAway
        case 1002:
          self = .protocolError
        case 1003:
          self = .unsupportedData
        case 1005:
          self = .noStatusReceived
        case 1006:
          self = .abnormalClosure
        case 1007:
          self = .invalidFramePayloadData
        case 1008:
          self = .policyViolation
        case 1009:
          self = .messageTooBig
        case 1010:
          self = .mandatoryExtensionMissing
        case 1011:
          self = .internalServerError
        case 1015:
          self = .tlsHandshakeFailure
        case 3000...3999:
          self = .applicationCode(rawValue)
        case 4000...4999:
          self = .privateCode(rawValue)
        default:
          self = .invalidCode(rawValue)
      }
    }

    /// The numeric value of the close code.
    public var rawValue: UInt16 {
      switch self {
        case .normalClosure:
          return 1000
        case .goingAway:
          return 1001
        case .protocolError:
          return 1002
        case .unsupportedData:
          return 1003
        case .noStatusReceived:
          return 1005
        case .abnormalClosure:
          return 1006
        case .invalidFramePayloadData:
          return 1007
        case .policyViolation:
          return 1008
        case .messageTooBig:
          return 1009
        case .mandatoryExtensionMissing:
          return 1010
        case .internalServerError:
          return 1011
        case .tlsHandshakeFailure:
          return 1015
        case .applicationCode(let value):
          return value
        case .privateCode(let value):
          return value
        case .invalidCode(let value):
          return value
      }
    }

    /// Whether the close code is restricted.
    ///
    /// Restricted close codes cannot be sent directly to another endpoint.
    public var isRestricted: Bool {
      switch self {
        case .noStatusReceived, .abnormalClosure, .tlsHandshakeFailure:
          return true
        default:
          return false
      }
    }
  }
}
