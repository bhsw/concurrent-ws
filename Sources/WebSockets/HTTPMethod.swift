// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation

/// An HTTP method.
public enum HTTPMethod: Equatable, RawRepresentable {

  /// The `GET` method.
  case get

  /// The `HEAD` method.
  case head

  /// The `POST` method.
  case post

  /// The `PUT` method.
  case put

  /// The `DELETE` method.
  case delete

  /// The `CONNECT` method.
  case connect

  /// The `OPTIONS` method.
  case options

  /// The `TRACE` method.
  case trace

  /// The `PATCH` method.
  case patch

  /// An HTTP method not known by this implementation.
  case other(String)

  /// Initializes an `HTTPMethod` from its string equivalent.
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

  /// The string representation of the method.
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

extension HTTPMethod: CustomDebugStringConvertible {
  public var debugDescription: String {
    rawValue
  }
}
