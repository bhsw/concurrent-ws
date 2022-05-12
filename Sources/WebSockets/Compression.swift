// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation
import zlib

// MARK: Negotiation

internal struct CompressionOffer {
  enum WindowBits {
    case empty
    case value(Int)

    var stringValue: String {
      switch self {
        case .empty:
          return ""
        case .value(let value):
          return String(value)
      }
    }

    var effectiveValue: Int {
      switch self {
        case .empty:
          return 15
        case .value(let value):
          return value
      }
    }
  }

  var serverNoContextTakeover: Bool?
  var serverMaxWindowBits: WindowBits?
  var clientNoContextTakeover: Bool?
  var clientMaxWindowBits: WindowBits?

  init(serverNoContextTakeover: Bool? = nil, serverMaxWindowBits: WindowBits? = nil,
       clientNoContextTakeover: Bool? = nil, clientMaxWindowBits: WindowBits? = nil) {
    self.serverNoContextTakeover = serverNoContextTakeover
    self.serverMaxWindowBits = serverMaxWindowBits
    self.clientNoContextTakeover = clientNoContextTakeover
    self.clientMaxWindowBits = clientMaxWindowBits
  }

  init?(from token: ParameterizedToken) {
    guard token.token == Keys.perMessageDeflate else {
      return nil
    }
    for (name, value) in token.parameters {
      switch name {
        case Keys.serverNoContextTakeover:
          guard serverNoContextTakeover == nil && value.isEmpty else {
            return nil
          }
          serverNoContextTakeover = true
        case Keys.serverMaxWindowBits:
          guard serverMaxWindowBits == nil, let bits = Int(value), bits >= 8, bits <= 15 else {
            return nil
          }
          serverMaxWindowBits = .value(bits)
        case Keys.clientNoContextTakeover:
          guard clientNoContextTakeover == nil, value.isEmpty else {
            return nil
          }
          clientNoContextTakeover = true
        case Keys.clientMaxWindowBits:
          guard clientMaxWindowBits == nil else {
            return nil
          }
          if value.isEmpty {
            clientMaxWindowBits = .empty
            continue
          }
          guard let bits = Int(value) else {
            return nil
          }
          clientMaxWindowBits = .value(bits)
        default:
          // Per the RFC, any other parameters invalidate the entire offer.
          return nil
      }
    }
  }

  var token: ParameterizedToken {
    var token = ParameterizedToken(token: Keys.perMessageDeflate)
    if let serverNoContextTakeover = serverNoContextTakeover, serverNoContextTakeover {
      token.set(parameter: Keys.serverNoContextTakeover, to: "")
    }
    if let serverMaxWindowBits = serverMaxWindowBits {
      token.set(parameter: Keys.serverMaxWindowBits, to: serverMaxWindowBits.stringValue)
    }
    if let clientNoContextTakeover = clientNoContextTakeover, clientNoContextTakeover {
      token.set(parameter: Keys.clientNoContextTakeover, to: "")
    }
    if let clientMaxWindowBits = clientMaxWindowBits {
      token.set(parameter: Keys.clientMaxWindowBits, to: clientMaxWindowBits.stringValue)
    }
    return token
  }

  func respond() -> CompressionOffer {
    return CompressionOffer(serverNoContextTakeover: serverNoContextTakeover,
                            serverMaxWindowBits: serverMaxWindowBits,
                            clientNoContextTakeover: clientNoContextTakeover)
  }

  private struct Keys {
    static let perMessageDeflate = "permessage-deflate"
    static let serverNoContextTakeover = "server_no_context_takeover"
    static let serverMaxWindowBits = "server_max_window_bits"
    static let clientNoContextTakeover = "client_no_context_takeover"
    static let clientMaxWindowBits = "client_max_window_bits"
  }
}

internal func firstValidCompressionOffer(from request: HTTPMessage) -> CompressionOffer? {
  for token in request.webSocketExtensions {
    if let offer = CompressionOffer(from: token) {
      return offer
    }
  }
  return nil
}

// MARK: Compression

/// Performs compression using the DEFLATE algorithm with options and output format requred by the `permessage-deflate`
/// WebSocket extension (RFC 7692).
class Deflater {
  private var stream = z_stream()
  private let noContextTakeover : Bool

  /// Initializes the compressor.
  /// - Parameter offer: The accepted compression offer.
  /// - Parameter forClient: Whether the deflater is being used by a client (`true`) or server (`false`)
  init(offer: CompressionOffer, forClient: Bool) {
    noContextTakeover = forClient ? offer.clientNoContextTakeover == true : offer.serverNoContextTakeover == true
    let maxWindowBits = forClient ? offer.clientMaxWindowBits : offer.serverMaxWindowBits
    precondition(deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, Int32(-(maxWindowBits?.effectiveValue ?? 15)),
                               Int32(8), Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
  }

  deinit {
    deflateEnd(&stream)
  }

  /// Compresses the given data.
  /// - Parameter data: The data to compress.
  /// - Returns: The compressed data.
  func compress(_ data: Data) -> Data {
    if data.isEmpty {
      return Data()
    }
    // We need to reserve extra space above what `deflateBound` returns because we're forcing a sync flush.
    let maxCompressedSize = Int(deflateBound(&stream, UInt(data.count)) + 5)
    let result = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: maxCompressedSize)
    return data.withUnsafeBytes { rawPtr in
      let ptr = rawPtr.bindMemory(to: UInt8.self)
      stream.next_in = UnsafeMutablePointer(mutating: ptr.baseAddress!)
      stream.avail_in = UInt32(ptr.count)
      stream.next_out = result.baseAddress!
      stream.avail_out = UInt32(result.count)
      precondition(deflate(&stream, noContextTakeover ? Z_FULL_FLUSH : Z_SYNC_FLUSH) == Z_OK)
      // RFC 7692 requires us to drop the final 4 bytes (which are always 0x00 0x00 0xff 0xff).
      return Data(bytesNoCopy: result.baseAddress!,
                  count: result.count - Int(stream.avail_out) - 4,
                  deallocator: .custom({ (ptr, length) in
        ptr.deallocate()
      }))
    }
  }
}

// MARK: Decompression

/// Performs decompression using the DEFLATE algorithm, as required by the `permessage-deflate` WebSocket extension (RFC 7692).
class Inflater {
  private var stream = z_stream()
  private let noContextTakeover: Bool
  private var outputBuf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 16384)

  /// Initializes the compressor.
  /// - Parameter offer: The accepted compression offer.
  /// - Parameter forClient: Whether the inflater is being used by a client (`true`) or server (`false`)
  init(offer: CompressionOffer, forClient: Bool) {
    noContextTakeover = forClient ? offer.clientNoContextTakeover == true : offer.serverNoContextTakeover == true
    precondition(inflateInit2_(&stream, Int32(-15), ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
  }

  deinit {
    inflateEnd(&stream)
    outputBuf.deallocate()
  }

  /// Decompresses the given data.
  /// - Parameter data: The data to decompress.
  /// - Returns: The decompressed data.
  /// - Throws: `InflateError.invalidInput` if the input data is corrupt or is not in the correct format.
  func decompress(_ data: Data) throws -> Data {
    var result = Data()
    if data.isEmpty {
      return result
    }
    try decompress(data, into: &result)
    // Restore the suffix we dropped during the compression step.
    try decompress(emptyBlock, into: &result)
    if noContextTakeover {
      inflateReset(&stream)
    }
    return result
  }

  private func decompress(_ data: Data, into result: inout Data) throws {
    try data.withUnsafeBytes { rawPtr -> Void in
      let ptr = rawPtr.bindMemory(to: UInt8.self)
      stream.next_in = UnsafeMutablePointer(mutating: ptr.baseAddress!)
      stream.avail_in = UInt32(ptr.count)
      repeat {
        stream.next_out = outputBuf.baseAddress!
        stream.avail_out = UInt32(outputBuf.count)
        switch inflate(&stream, Z_NO_FLUSH) {
          case Z_DATA_ERROR:
            throw InflateError.invalidInput(String(cString: stream.msg))
          case Z_OK, Z_STREAM_END:
            break
          default:
            preconditionFailure()
        }
        result.append(outputBuf.baseAddress!, count: outputBuf.count - Int(stream.avail_out))
      } while stream.avail_in != 0
    }
  }
}

fileprivate let emptyBlock = Data([ 0x00, 0x00, 0xff, 0xff ])

enum InflateError: Error {
  case invalidInput(String)
}
