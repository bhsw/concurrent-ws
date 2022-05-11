// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation
import zlib

typealias ContiguousDataProtocol = ContiguousBytes & DataProtocol

/// Performs compression using the DEFLATE algorithm with options and output format requred by the r the `permessage-deflate`
/// WebSocket extension (RFC 7692).
class Deflater {
  private var stream = z_stream()
  private let sharedWindow: Bool

  /// Initializes the compressor.
  /// - Parameter windowBits: The window bits (8-15).
  /// - Parameter sharedWindow: Whether multiple calls to `compress` should share the same sliding window.
  init(windowBits: Int = 15, sharedWindow: Bool = true) {
    self.sharedWindow = sharedWindow
    precondition(deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, Int32(-windowBits), Int32(8), Z_DEFAULT_STRATEGY,
                               ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
  }

  deinit {
    deflateEnd(&stream)
  }

  /// Compresses the given data.
  /// - Parameter data: The data to compress.
  /// - Returns: The compressed data.
  func compress<T>(_ data: T) -> Data where T: ContiguousDataProtocol {
    if data.isEmpty {
      return Data()
    }
    let maxCompressedSize = Int(deflateBound(&stream, UInt(data.count)) + 5)
    let result = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: maxCompressedSize)
    return data.withUnsafeBytes { rawPtr in
      let ptr = rawPtr.bindMemory(to: UInt8.self)
      stream.next_in = UnsafeMutablePointer(mutating: ptr.baseAddress!)
      stream.avail_in = UInt32(ptr.count)
      stream.next_out = result.baseAddress!
      stream.avail_out = UInt32(result.count)
      precondition(deflate(&stream, sharedWindow ? Z_SYNC_FLUSH : Z_FULL_FLUSH) == Z_OK)
      return Data(bytesNoCopy: result.baseAddress!,
                  count: result.count - Int(stream.avail_out) - 4,
                  deallocator: .custom({ (ptr, length) in
        ptr.deallocate()
      }))
    }
  }
}

/// Performs decompression using the DEFLATE algorithm, as required for the `permessage-deflate` WebSocket extension (RFC 7692).
class Inflater {
  private var stream = z_stream()
  private let sharedWindow: Bool
  private var outputBuf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 16384)

  /// Initializes the compressor.
  /// - Parameter sharedWindow: Whether multiple calls to `decompress` should share the same sliding window.
  init(sharedWindow: Bool = true) {
    self.sharedWindow = sharedWindow
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
  func decompress<T>(_ data: T) throws -> Data where T: ContiguousDataProtocol {
    var result = Data()
    if data.isEmpty {
      return result
    }
    try decompress(data, into: &result)
    try decompress([ 0x00, 0x00, 0xff, 0xff], into: &result)
    if !sharedWindow {
      inflateReset(&stream)
    }
    return result
  }

  private func decompress<T>(_ data: T, into result: inout Data) throws where T: ContiguousDataProtocol{
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

enum InflateError: Error {
  case invalidInput(String)
}
