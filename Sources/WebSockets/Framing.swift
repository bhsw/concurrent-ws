// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation

// MARK: Frame

internal enum Frame {
  case text(String)
  case binary(Data)
  case close(WebSocket.CloseCode?, String)
  case ping(Data)
  case pong(Data)
  case protocolError(ProtocolError)
  case messageTooBig

  var isError: Bool {
    switch self {
      case .protocolError(_):
        return true
      case .messageTooBig:
        return true
      default:
        return false
    }
  }
}

// MARK: ProtocolError

internal enum ProtocolError: Error, CustomDebugStringConvertible {
  case invalidOpcode
  case invalidUTF8
  case invalidLength
  case maskedPayloadRequired
  case maskedPayloadForbidden
  case unexpectedContinuation
  case reservedBitsNonzero
  case forbiddenOpcodeForCompression
  case invalidCompressedData

  var debugDescription: String {
    switch self {
      case .invalidOpcode:
        return "Invalid opcode"
      case .invalidUTF8:
        return "Invalid UTF-8 data"
      case .invalidLength:
        return "Invalid payload length"
      case .maskedPayloadRequired:
        return "Masked payload required"
      case .maskedPayloadForbidden:
        return "Masked payload forbidden"
      case .unexpectedContinuation:
        return "Unexpected continuation frame"
      case .reservedBitsNonzero:
        return "Reserved bits must be 0"
      case .forbiddenOpcodeForCompression:
        return "Forbidden opcode for compression"
      case .invalidCompressedData:
        return "Invalid compressed data"
    }
  }
}

// MARK: OutputFramer

internal struct OutputFramer {
  private let isClient: Bool
  private var deflater: Deflater? = nil
  private(set) var statistics = WebSocket.Statistics()

  init(forClient isClient: Bool, compression: DeflateParameters? = nil) {
    self.isClient = isClient
    if let compression = compression {
      deflater = Deflater(offer: compression, forClient: isClient)
    }
  }

  mutating func encode(_ frame: Frame, compress: Bool = true) -> [Data] {
    let key: UInt32? = isClient ? UInt32.random(in: 1..<UInt32.max) : nil
    switch frame {
      case .text(let text):
        statistics.textMessageCount &+= 1
        let payload = text.data(using: .utf8)!
        if compress && !payload.isEmpty && deflater != nil {
          let compressedPayload = deflater!.compress(payload)
          statistics.compressedTextBytesSaved &+= Int64(payload.count - compressedPayload.count)
          statistics.compressedTextMessageCount &+= 1
          statistics.textBytesTransferred &+= Int64(compressedPayload.count)
          statistics.compressedTextBytesTransferred &+= Int64(compressedPayload.count)
          return encode(as: .text, payload: compressedPayload, using: key, compressed: true)
        }
        statistics.textBytesTransferred &+= Int64(payload.count)
        return encode(as: .text, payload: payload, using: key, compressed: false)
      case .binary(let payload):
        statistics.binaryMessageCount &+= 1
        if compress && !payload.isEmpty && deflater != nil {
          let compressedPayload = deflater!.compress(payload)
          statistics.compressedBinaryBytesSaved &+= Int64(payload.count - compressedPayload.count)
          statistics.compressedBinaryMessageCount &+= 1
          statistics.binaryBytesTransferred &+= Int64(compressedPayload.count)
          statistics.compressedBinaryBytesTransferred &+= Int64(compressedPayload.count)
          return encode(as: .binary, payload: compressedPayload, using: key, compressed: true)
        }
        statistics.binaryBytesTransferred &+= Int64(payload.count)
        return encode(as: .binary, payload: payload, using: key, compressed: false)
      case .close(let code, let reason):
        statistics.controlFrameCount += 1
        var payload = Data()
        if let code = code {
          payload.appendBigEndian(code.rawValue)
          var reasonBytes = reason.data(using: .utf8)!
          if reasonBytes.count > maxCloseReasonSize {
            // Truncate the UTF-8 data if it exceeds the space available.
            reasonBytes.removeSubrange(maxCloseReasonSize...)
            // Ensure that we end on a codepoint boundary.
            while String(data: reasonBytes, encoding: .utf8) == nil {
              reasonBytes.removeLast()
            }
          }
          payload.append(reasonBytes)
        }
        return encode(as: .close, payload: payload, using: key)
      case .ping(let data):
        statistics.controlFrameCount += 1
        return encode(as: .ping, payload: data.count <= maxControlPayloadSize ? data : data[0..<maxControlPayloadSize], using: key)
      case .pong(let data):
        statistics.controlFrameCount += 1
        return encode(as: .pong, payload: data.count <= maxControlPayloadSize ? data : data[0..<maxControlPayloadSize], using: key)
      default:
        // The other frame types are errors emitted by the input framer; they cannot be encoded.
        preconditionFailure()
    }
  }

  mutating func enableCompression(offer: DeflateParameters) {
    precondition(deflater == nil)
    deflater = Deflater(offer: offer, forClient: isClient)
  }

  mutating func resetStatistics() {
    statistics = WebSocket.Statistics()
  }

  private mutating func encode(as opcode: Opcode, payload: Data, using maskKey: UInt32? = nil,
                               compressed: Bool = false, fin: Bool = true) -> [Data] {
    var header = Data(capacity: maxHeaderSize + payload.count)
    header.append((opcode.rawValue & 0xf) | (fin ? 0x80 : 0) | (compressed ? 0x40 : 0))
    let maskBit: UInt8 = maskKey != nil ? 0x80 : 0
    switch payload.count {
      case 0...125:
        header.append(UInt8(payload.count) | maskBit)
      case 126...65535:
        header.append(126 | maskBit)
        header.appendBigEndian(UInt16(payload.count))
      default:
        header.append(127 | maskBit)
        header.appendBigEndian(UInt64(payload.count))
    }
    if let key = maskKey {
      header.appendBigEndian(key)
      guard !payload.isEmpty else {
        return [ header ]
      }
      var maskedPayload = payload
      maskedPayload.mask(using: key, range:maskedPayload.startIndex..<maskedPayload.endIndex)
      return [ header, maskedPayload ]
    }
    return payload.isEmpty ? [ header ] : [ header, payload ]
  }
}

// MARK: InputFramer

internal struct InputFramer {
  private let isClient: Bool
  private let maximumMessageSize: Int
  private var state: State = .opcode
  private var opcode: Opcode? = nil
  private var messageOpcode: Opcode? = nil
  private var compressed = false
  private var fin = false
  private var masked = false
  private var payloadLength: UInt64 = 0
  private var payloadRemaining: Int = 0
  private var maskKey: UInt32 = 0
  private var messagePayload: Data? = nil
  private var controlPayload: Data? = nil
  private var frames: [Frame] = []
  private var fatal = false
  private var inflater: Inflater? = nil
  private(set) var statistics = WebSocket.Statistics()

  init(forClient isClient: Bool, maximumMessageSize: Int, compression: DeflateParameters? = nil) {
    self.isClient = isClient
    self.maximumMessageSize = maximumMessageSize
    if let compression = compression {
      inflater = Inflater(offer: compression, forClient: isClient)
    }
  }

  mutating func push(_ input: Data) {
    guard !fatal else {
      return
    }
    var index = input.startIndex
    while !fatal && index != input.endIndex {
      var c = input[index]
      switch state {
        case .opcode:
          guard let opcode = Opcode(rawValue: c & 0x0f) else {
            emit(frame: .protocolError(.invalidOpcode))
            return
          }
          fin = c & 0x80 != 0
          let rsv1 = c & 0x40 != 0, rsv2 = c & 0x20 != 0, rsv3 = c & 0x10 != 0
          guard !rsv2 && !rsv3 else {
            emit(frame: .protocolError(.reservedBitsNonzero))
            return
          }
          if (rsv1) {
            guard inflater != nil else {
              emit(frame: .protocolError(.reservedBitsNonzero))
              return
            }
            guard opcode.isMessageStart else {
              emit(frame: .protocolError(.forbiddenOpcodeForCompression))
              return
            }
            compressed = true
          }
          guard opcode != .continuation || messagePayload != nil else {
            emit(frame: .protocolError(.unexpectedContinuation))
            return
          }
          self.opcode = opcode
          if (opcode.isMessageStart) {
            messageOpcode = opcode
          }
          state.next()
        case .length:
          masked = c & 0x80 != 0
          if (masked != !isClient) {
            // The WebSocket spec requires the connection to be torn down if this happens.
            emit(frame: .protocolError(isClient ? .maskedPayloadForbidden : .maskedPayloadRequired))
            return
          }
          c &= 0x7f
          switch c {
            case 0:
              payloadLength = 0
              if (masked) {
                state = .maskKey0
              } else {
                finishZeroLengthPayload()
              }
            case 1...125:
              payloadLength = UInt64(c)
              guard acceptPayloadLength() else {
                return
              }
            case 126:
              state = .shortExtendedLength0
            default:
              state =  .longExtendedLength0
          }
        case .shortExtendedLength0, .longExtendedLength0:
          payloadLength = UInt64(c)
          state.next()
        case .shortExtendedLength1, .longExtendedLength7:
          payloadLength <<= 8
          payloadLength |= UInt64(c)
          guard payloadLength < Int.max else {
            emit(frame: .protocolError(.invalidLength))
            return
          }
          guard acceptPayloadLength() else {
            return
          }
        case .longExtendedLength1, .longExtendedLength2, .longExtendedLength3,
            .longExtendedLength4, .longExtendedLength5, .longExtendedLength6:
          payloadLength <<= 8
          payloadLength |= UInt64(c)
          state.next()
        case .maskKey0:
          maskKey = UInt32(c)
          state.next()
        case .maskKey1, .maskKey2:
          maskKey <<= 8
          maskKey |= UInt32(c)
          state.next()
        case .maskKey3:
          maskKey <<= 8
          maskKey |= UInt32(c)
          if payloadLength == 0 {
            finishZeroLengthPayload()
          } else {
            state = opcode!.isMessage ? .messagePayload : .controlPayload
          }
        case .messagePayload:
          if (messagePayload == nil) {
            messagePayload = Data(capacity: payloadRemaining)
          }
          let count = min(payloadRemaining, input.endIndex - index)
          messagePayload!.append(input[index..<index + count])
          payloadRemaining -= count
          index += count
          if (payloadRemaining == 0) {
            if (masked) {
              let start = messagePayload!.endIndex - Int(payloadLength)
              messagePayload!.mask(using: maskKey, range: start..<messagePayload!.endIndex)
            }
            if (fin) {
              emit(frame: decompressFrame(of: messageOpcode!, payload: messagePayload!))
              messagePayload = nil
              messageOpcode = nil
            }
            opcode = nil
            state = .opcode
          }
          continue
        case .controlPayload:
          if (controlPayload == nil) {
            controlPayload = Data(capacity: payloadRemaining)
          }
          let count = min(payloadRemaining, input.endIndex - index)
          controlPayload!.append(input[index..<index + count])
          payloadRemaining -= count
          index += count
          if (payloadRemaining == 0) {
            if (masked) {
              controlPayload!.mask(using: maskKey, range: controlPayload!.startIndex..<controlPayload!.endIndex)
            }
            emit(frame: decodeFrame(of: opcode!, payload: controlPayload!))
            controlPayload = nil
            opcode = nil
            state = .opcode
          }
          continue
      }
      index += 1
    }
  }

  mutating func pop() -> Frame? {
    return frames.isEmpty ? nil : frames.removeFirst()
  }

  mutating func reset() {
    frames.removeAll()
    messagePayload = nil
    controlPayload = nil
    state = .opcode
    opcode = nil
    messageOpcode = nil
    compressed = false
    fatal = false
  }

  mutating func enableCompression(offer: DeflateParameters) {
    precondition(inflater == nil)
    inflater = Inflater(offer: offer, forClient: isClient)
  }

  mutating func resetStatistics() {
    statistics = WebSocket.Statistics()
  }

  private mutating func acceptPayloadLength() -> Bool {
    if opcode!.isMessage {
      let remaining = maximumMessageSize - (messagePayload?.count ?? 0)
      guard remaining >= payloadLength else {
        emit(frame: .messageTooBig)
        return false
      }
      state = masked ? .maskKey0 : .messagePayload
    } else {
      state = masked ? .maskKey0 : .controlPayload
    }
    payloadRemaining = Int(payloadLength)
    return true
  }

  private mutating func finishZeroLengthPayload() {
    if (opcode!.isMessage) {
      if (fin) {
        emit(frame: decompressFrame(of: messageOpcode!, payload: messagePayload ?? Data()))
        messagePayload = nil
        messageOpcode = nil
      }
    } else {
      emit(frame: decodeFrame(of: opcode!, payload: Data()))
    }
    opcode = nil
    state = .opcode
  }

  private mutating func decompressFrame(of opcode: Opcode, payload: Data) -> Frame {
    if !compressed {
      return decodeFrame(of: opcode, payload: payload)
    }
    compressed = false
    guard let result = try? decodeFrame(of: opcode, payload: inflater!.decompress(payload), compressedSize: payload.count) else {
      return .protocolError(.invalidCompressedData)
    }
    return result
  }

  private mutating func decodeFrame(of opcode: Opcode, payload: Data, compressedSize: Int? = nil) -> Frame {
    switch opcode {
      case .text:
        statistics.textMessageCount &+= 1
        if let compressedSize = compressedSize {
          statistics.compressedTextMessageCount &+= 1
          statistics.textBytesTransferred &+= Int64(compressedSize)
          statistics.compressedTextBytesTransferred &+= Int64(compressedSize)
          statistics.compressedTextBytesSaved &+= Int64(payload.count - compressedSize)
        } else {
          statistics.textBytesTransferred &+= Int64(payload.count)
        }
        guard let text = String(bytes: payload, encoding: .utf8) else {
          return .protocolError(.invalidUTF8)
        }
        return .text(text)
      case .binary:
        statistics.binaryMessageCount &+= 1
        if let compressedSize = compressedSize {
          statistics.compressedBinaryMessageCount &+= 1
          statistics.binaryBytesTransferred &+= Int64(compressedSize)
          statistics.compressedBinaryBytesTransferred &+= Int64(compressedSize)
          statistics.compressedBinaryBytesSaved &+= Int64(payload.count - compressedSize)
        } else {
          statistics.binaryBytesTransferred &+= Int64(payload.count)
        }
        return .binary(payload)
      case .close:
        statistics.controlFrameCount &+= 1
        if payload.count < 2 {
          return .close(nil, "")
        }
        let code = WebSocket.CloseCode(rawValue: (UInt16(payload[payload.startIndex]) << 8) |
                                                  UInt16(payload[payload.startIndex + 1]))
        guard let reason = String(data: payload[(payload.startIndex + 2)...], encoding: .utf8) else {
          return .protocolError(.invalidUTF8)
        }
        return .close(code, reason)
      case .ping:
        statistics.controlFrameCount &+= 1
        return .ping(payload)
      case .pong:
        statistics.controlFrameCount &+= 1
        return .pong(payload)
      default:
        return .protocolError(.invalidOpcode)
    }
  }

  private mutating func emit(frame: Frame) {
    if (frame.isError) {
      fatal = true
    }
    frames.append(frame)
  }

  private enum State : Int {
    case opcode
    case length
    case shortExtendedLength0
    case shortExtendedLength1
    case longExtendedLength0
    case longExtendedLength1
    case longExtendedLength2
    case longExtendedLength3
    case longExtendedLength4
    case longExtendedLength5
    case longExtendedLength6
    case longExtendedLength7
    case maskKey0
    case maskKey1
    case maskKey2
    case maskKey3
    case messagePayload
    case controlPayload

    mutating func next() {
      self = State(rawValue: self.rawValue + 1)!
    }
  }
}

// MARK: Opcode

enum Opcode : UInt8 {
  case continuation = 0
  case text = 1
  case binary = 2
  case close = 8
  case ping = 9
  case pong = 10

  var isMessageStart: Bool {
    self == .text || self == .binary
  }

  var isMessage: Bool {
    self == .text || self == .binary || self == .continuation
  }
}

// MARK: Private Data extension

fileprivate extension Data {
  mutating func mask(using key: UInt32, range: Range<Data.Index>) {
    let mask: [UInt8] = [
      UInt8(key >> 24),
      UInt8(key >> 16 & 255),
      UInt8(key >> 8 & 255),
      UInt8(key & 255)
    ]
    self.withUnsafeMutableBytes { ptr in
      var index = range.startIndex
      var maskIndex = 0
      while index < range.endIndex {
        ptr[index] ^= mask[maskIndex & 3]
        index &+= 1
        maskIndex &+= 1
      }
    }
  }

  mutating func appendBigEndian(_ value: UInt16) {
    self.append(UInt8(value >> 8))
    self.append(UInt8(value & 0xff))
  }

  mutating func appendBigEndian(_ value: UInt32) {
    self.append(UInt8(value >> 24))
    self.append(UInt8(value >> 16 & 0xff))
    self.append(UInt8(value >> 8 & 0xff))
    self.append(UInt8(value & 0xff))
  }

  mutating func appendBigEndian(_ value: UInt64) {
    self.append(UInt8(value >> 56))
    self.append(UInt8(value >> 48 & 0xff))
    self.append(UInt8(value >> 40 & 0xff))
    self.append(UInt8(value >> 32 & 0xff))
    self.append(UInt8(value >> 24 & 0xff))
    self.append(UInt8(value >> 16 & 0xff))
    self.append(UInt8(value >> 8 & 0xff))
    self.append(UInt8(value & 0xff))
  }
}

// MARK: Protocol constants

fileprivate let maxHeaderSize = 1 + 1 + 8 + 4
fileprivate let maxControlPayloadSize = 125
fileprivate let maxCloseReasonSize = maxControlPayloadSize - 2
