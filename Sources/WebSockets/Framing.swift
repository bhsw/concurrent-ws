// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation

// MARK: Frame

internal enum Frame {
  case text(String)
  case binary(Data)
  case close(WebSocket.CloseCode, String)
  case ping(Data)
  case pong(Data)
  case protocolError(ProtocolError)
  case policyViolation(PolicyViolation)

  var isError: Bool {
    switch self {
      case .protocolError(_):
        return true
      case .policyViolation(_):
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
    }
  }
}

// MARK: PolicyViolation

internal enum PolicyViolation: Error, CustomDebugStringConvertible {
  case maximumMessageSizeExceeded

  var debugDescription: String {
    switch self {
      case .maximumMessageSizeExceeded:
        return "Maximum message size exceeded"
    }
  }
}

// MARK: OutputFramer

internal struct OutputFramer {
  private let isClient: Bool
  private var output: Data? = nil

  init(forClient isClient: Bool) {
    self.isClient = isClient
  }

  mutating func push(_ frame: Frame) -> Bool {
    let key: UInt32? = isClient ? UInt32.random(in: 1..<UInt32.max) : nil
    switch frame {
      case .text(let text):
        let data = [UInt8](text.utf8)
        push(opcode: .text, payload: data, using: key)
      case .binary(let data):
        push(opcode: .binary, payload: data, using: key)
      case .close(let code, let reason):
        var data = Data()
        data.appendBigEndian(code.rawValue)
        guard var reasonBytes = reason.data(using: .utf8) else {
          return false
        }
        if reasonBytes.count > maxCloseReasonSize {
          // Truncate the UTF-8 data if it exceeds the space available.
          reasonBytes.removeSubrange(maxCloseReasonSize...)
          // Ensure that we end on a codepoint boundary.
          while String(data: reasonBytes, encoding: .utf8) == nil {
            reasonBytes.removeLast()
          }
        }
        data.append(reasonBytes)
        push(opcode: .close, payload: data, using: key)
      case .ping(let data):
        guard data.count <= maxControlPayloadSize else {
          return false
        }
        push(opcode: .ping, payload: data, using: key)
      case .pong(let data):
        guard data.count <= maxControlPayloadSize else {
          return false
        }
        push(opcode: .pong, payload: data, using: key)
      default:
        return false
    }
    return true
  }

  mutating func pop() -> Data? {
    let result = output
    output = nil
    return result
  }

  mutating func reset() {
    output = nil
  }

  private mutating func push<T : Collection>(opcode: Opcode, payload: T, using maskKey: UInt32? = nil, fin: Bool = true) where T.Element == UInt8 {
    if (output == nil) {
      output = Data(capacity: payload.count + maxHeaderSize)
    }
    output!.append((opcode.rawValue & 0xf) | (fin ? 0x80 : 0))
    let maskBit: UInt8 = maskKey != nil ? 0x80 : 0
    switch payload.count {
      case 0...125:
        output!.append(UInt8(payload.count) | maskBit)
      case 126...65535:
        output!.append(126 | maskBit)
        output!.appendBigEndian(UInt16(payload.count))
      default:
        output!.append(127 | maskBit)
        output!.appendBigEndian(UInt64(payload.count))
    }
    if let key = maskKey {
      output!.appendBigEndian(key)
      output!.append(payload, usingMask: key)
    } else {
      output!.append(contentsOf: payload)
    }
  }
}

// MARK: InputFramer

internal struct InputFramer {
  private let isClient: Bool
  private let maximumMessageSize: Int
  private var state: State = .opcode
  private var opcode: Opcode? = nil
  private var messageOpcode: Opcode? = nil
  private var fin = false
  private var masked = false
  private var payloadLength: UInt64 = 0
  private var payloadRemaining: Int = 0
  private var maskKey: UInt32 = 0
  private var messagePayload: Data? = nil
  private var controlPayload: Data? = nil
  private var frames: [Frame] = []
  private var fatal = false

  init(forClient isClient: Bool, maximumMessageSize: Int) {
    self.isClient = isClient
    self.maximumMessageSize = maximumMessageSize
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
          guard c & 0x70 == 0 else {
            emit(frame: .protocolError(.reservedBitsNonzero))
            return
          }
          guard let opcode = Opcode(rawValue: c & 0x0f) else {
            emit(frame: .protocolError(.invalidOpcode))
            return
          }
          guard opcode != .continuation || messagePayload != nil else {
            emit(frame: .protocolError(.unexpectedContinuation))
            return
          }
          self.opcode = opcode
          if (opcode.isMessageStart) {
            messageOpcode = opcode
          }
          fin = c & 0x80 != 0
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
            payloadRemaining = Int(payloadLength)
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
              emit(frame: decodeFrame(of: messageOpcode!, payload: messagePayload!))
              messagePayload = nil
              messageOpcode = nil
            }
            opcode = nil
            state = .opcode
          }
          continue
        case .controlPayload:
          if (controlPayload == nil) {
            payloadRemaining = Int(payloadLength)
            controlPayload = Data(capacity: payloadRemaining)
          }
          let count = min(payloadRemaining, input.endIndex - index)
          controlPayload!.append(input[index..<index + count])
          payloadRemaining -= count
          index += count
          if (payloadRemaining == 0) {
            if (masked) {
              controlPayload!.mask(using: maskKey, range: 0..<controlPayload!.count)
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
    fatal = false
  }

  private mutating func acceptPayloadLength() -> Bool {
    if opcode!.isMessage {
      let remaining = maximumMessageSize - (messagePayload?.count ?? 0)
      guard remaining >= payloadLength else {
        emit(frame: .policyViolation(.maximumMessageSizeExceeded))
        return false
      }
      state = masked ? .maskKey0 : .messagePayload
    } else {
      state = masked ? .maskKey0 : .controlPayload
    }
    return true
  }

  private mutating func finishZeroLengthPayload() {
    if (opcode!.isMessage) {
      if (fin) {
        emit(frame: decodeFrame(of: messageOpcode!, payload: messagePayload ?? Data()))
        messagePayload = nil
        messageOpcode = nil
      }
    } else {
      emit(frame: decodeFrame(of: opcode!, payload: Data()))
    }
    opcode = nil
    state = .opcode
  }

  private func decodeFrame(of opcode: Opcode, payload: Data) -> Frame {
    switch opcode {
      case .text:
        guard let text = String(bytes: payload, encoding: .utf8) else {
          return .protocolError(.invalidUTF8)
        }
        return .text(text)
      case .binary:
        return .binary(payload)
      case .close:
        let code: UInt16 = payload.count >= 2 ? (UInt16(payload[0]) << 8) | UInt16(payload[1]) : 1005
        guard let reason = String(bytes: payload.count >= 2 ? payload[2...] : payload, encoding: .utf8) else {
          return .protocolError(.invalidUTF8)
        }
        return .close(.init(rawValue: code), reason)
      case .ping:
        return .ping(payload)
      case .pong:
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
    var maskIndex = 0
    for index in range {
      self[index] ^= mask[maskIndex]
      maskIndex += 1
      maskIndex &= 3
    }
  }

  mutating func append<T : Collection>(_ data: T, usingMask key: UInt32) where T.Element == UInt8 {
    let mask: [UInt8] = [
      UInt8(key >> 24),
      UInt8(key >> 16 & 255),
      UInt8(key >> 8 & 255),
      UInt8(key & 255)
    ]
    var maskIndex = 0
    for c in data {
      append(c ^ mask[maskIndex])
      maskIndex += 1
      maskIndex &= 3
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
