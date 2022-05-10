// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation

/// A type of error that may be thrown during the `connecting` state of the socket.
public enum WebSocketError: Error {
  /// An attempt was made to connect to an invalid URL.
  case invalidURL(URL)

  /// An attempt was made to connect to an URL with a scheme other than `ws` or `wss`.
  case invalidURLScheme(String)

  /// The requested hostname could not be resolved to a valid address.
  case hostLookupFailed(reason: String, underlyingError: Error)

  /// The connection could not be established.
  case connectionFailed(reason: String, underlyingError: Error)

  /// Security for the connection could not be established.
  case tlsFailed(reason: String, underlyingError: Error)

  /// The HTTP request is invalid. This usually indicates that a custom header contains characters that cannot be encoded as ISO-8859-1.
  case invalidHTTPRequest

  /// A malformed HTTP response was received from the other endpoint during the handshake.
  case invalidHTTPResponse

  /// The server rejected the request to upgrade to the WebSocket protocol.
  case upgradeRejected

  /// The server's response did not include a valid `Connection` header.
  case invalidConnectionHeader

  /// The server did not provide the expected key.
  case keyMismatch

  /// The endpoints did not agree on a subprotocol.
  case subprotocolMismatch

  /// An extension was asserted by the other endpoint without negotiating for it.
  case extensionMismatch

  /// An HTTP redirect response did not include a valid `Location` header.
  case invalidRedirection

  /// The server responded with an unexpected status code.
  case unexpectedHTTPStatus(WebSocket.FailedHandshakeResult)

  /// The other endpoint dropped the connection before the handshake completed.
  case unexpectedDisconnect

  /// The handshake did not complete within the specified timeframe.
  case timeout

  /// The redirect limit was exceeded. This usually indicates a redirect loop.
  case maximumRedirectsExceeded

  /// The redirect location was not a valid URL or relative URL.
  case invalidRedirectLocation(String)

  /// The listener for a ``WebSocketServer`` failed.
  case listenerFailed(reason: String, underlyingError: Error)
}

extension WebSocketError: CustomDebugStringConvertible {
  /// A description of the error suitable for debugging.
  public var debugDescription: String {
    switch self {
      case .invalidURL(let url):
        return "Invalid URL: \(url)"
      case .invalidURLScheme(let scheme):
        return "Invalid WebSocket URL scheme: \(scheme)"
      case .hostLookupFailed(reason: let reason, underlyingError: _):
        return "Host lookup failed: \(reason)"
      case .connectionFailed(reason: let reason, underlyingError: _):
        return "Connection failed: \(reason)"
      case .tlsFailed(reason: let reason, underlyingError: _):
        return "Failed to establish TLS: \(reason)"
      case .invalidHTTPRequest:
        return "Invalid HTTP request"
      case .invalidHTTPResponse:
        return "Invalid HTTP response"
      case .upgradeRejected:
        return "WebSocket upgrade rejected"
      case .invalidConnectionHeader:
        return "Invalid Connection header"
      case .keyMismatch:
        return "WebSocket key mismatch"
      case .subprotocolMismatch:
        return "WebSocket subprotocol expectation mismatch"
      case .extensionMismatch:
        return "WebSocket extension expectation mismatch"
      case .invalidRedirection:
        return "Invalid HTTP redirect"
      case .unexpectedHTTPStatus(let status):
        return "Unexpected HTTP status for WebSocket upgrade: \(status)"
      case .unexpectedDisconnect:
        return "Unexpected disconnect"
      case .timeout:
        return "WebSocket handshake timed out"
      case .maximumRedirectsExceeded:
        return "Maximum number of HTTP redirects exceeded"
      case .invalidRedirectLocation(let location):
        return "Invalid HTTP redirect location: \(location)"
      case .listenerFailed(reason: let reason, underlyingError: _):
        return "HTTP server error: \(reason)"
    }
  }
}
