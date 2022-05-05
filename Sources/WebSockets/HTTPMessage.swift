import Foundation

/// An HTTP request or response, with just enough functionality to support the WebSocket opening handshake.
internal struct HTTPMessage {
  enum Kind {
    case request
    case response
  }

  let kind : Kind
  var version: String
  var method: HTTPMethod?
  var target: String?
  var status: HTTPStatus?
  var reason: String?
  var host: String?
  var location: String?
  var upgrade: [ProtocolIdentifier] = []
  var connection: [String] = []
  var webSocketKey: String?
  var webSocketProtocol: [String] = []
  var webSocketVersion: [Int] = []
  var webSocketAccept: String?
  var webSocketExtensions: [ParameterizedToken] = []
  var contentLength: Int?
  var transferEncoding: [ParameterizedToken] = []
  var contentType: ParameterizedToken?
  var extraHeaders: [String: String] = [:]
  var content: Data?

  init(method: HTTPMethod, target: String, version: String="1.1") {
    self.kind = .request
    self.version = version
    self.method = method
    self.target = target
  }

  init(status: HTTPStatus, reason: String, version: String="1.1") {
    self.kind = .response
    self.version = version
    self.status = status
    self.reason = reason
  }

  mutating func addUpgrade(_ option: ProtocolIdentifier) {
    if !upgrade.contains(option) {
      upgrade.append(option)
      addConnection("upgrade")
    }
  }

  mutating func addConnection(_ option: String) {
    if !connection.contains(option) {
      connection.append(option)
    }
  }

  mutating func addWebSocketProtocol(_ proto: String) {
    if !webSocketProtocol.contains(proto) {
      webSocketProtocol.append(proto)
    }
  }

  mutating func addWebSocketVersion(_ version: Int) {
    if !webSocketVersion.contains(version) {
      webSocketVersion.append(version)
    }
  }

  mutating func addWebSocketExtension(_ specifier: ParameterizedToken) {
    if !webSocketExtensions.contains(specifier) {
      webSocketExtensions.append(specifier)
    }
  }

  var headerString: String {
    var result = firstLine + "\r\n"
    if let host = host {
      result += "Host: \(host)\r\n"
    }
    if let location = location {
      result += "Location: \(location)\r\n"
    }
    if !upgrade.isEmpty {
      result += "Upgrade: \(upgrade.map { String($0) }.joined(separator: ", "))\r\n"
    }
    if !connection.isEmpty {
      result += "Connection: \(connection.joined(separator: ", "))\r\n"
    }
    if let key = webSocketKey {
      result += "Sec-WebSocket-Key: \(key)\r\n"
    }
    if !webSocketProtocol.isEmpty {
      result += "Sec-WebSocket-Protocol: \(webSocketProtocol.joined(separator: ", "))\r\n"
    }
    if !webSocketVersion.isEmpty {
      result += "Sec-WebSocket-Version: \(webSocketVersion.map { String($0) }.joined(separator: ", "))\r\n"
    }
    if let key = webSocketAccept {
      result += "Sec-WebSocket-Accept: \(key)\r\n"
    }
    if !webSocketExtensions.isEmpty {
      let value = webSocketExtensions.map { $0.format() }.joined(separator: ", ")
      result += "Sec-WebSocket-Extensions: \(value)\r\n"
    }
    if let contentLength = contentLength {
      result += "Content-Length: \(contentLength)\r\n"
    }
    if let contentType = contentType {
      result += "Content-Type: \(contentType.format())\r\n"
    }
    for (name, value) in extraHeaders {
      if !isForbiddenHeader(name: name) {
        result += "\(name): \(value)\r\n"
      }
    }
    result += "\r\n"
    return result
  }

  func encode() -> Data? {
    print(headerString)
    guard var data = headerString.data(using: .isoLatin1) else {
      return nil
    }
    if let content = content {
      data += content
    }
    return data
  }
}

// MARK: Private Implementation

private extension HTTPMessage {
  var firstLine: String {
    switch kind {
      case .request:
        return method!.rawValue + " " + target! + " HTTP/" + version
      case .response:
        return "HTTP/" + version + " " + String(status!.rawValue) + " " + reason!
    }
  }

  mutating func addHeader(of name: String, value: String) {
    let key = name.lowercased()
    switch key {
      case "host":
        host = value
      case "upgrade":
        upgrade += value.split(separator: ",").map { ProtocolIdentifier($0.trimmingCharacters(in: .whitespaces)) }
      case "connection":
        connection += value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      case "sec-websocket-key":
        webSocketKey = value
      case "sec-websocket-protocol":
        webSocketProtocol += value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      case "sec-websocket-version":
        webSocketVersion += value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
      case "sec-websocket-accept":
        webSocketAccept = value
      case "sec-websocket-extensions":
        webSocketExtensions += ParameterizedToken.parseList(from: value)
      case "transfer-encoding":
        transferEncoding += ParameterizedToken.parseList(from: value)
      case "content-length":
        contentLength = Int(value)
      case "content-type":
        contentType = ParameterizedToken.parse(from: value)
      default:
        if let oldValue = extraHeaders[key] {
          extraHeaders[key] = oldValue + ", " + value
        } else {
          extraHeaders[key] = value
        }
    }
  }
}

// MARK: Parser

extension HTTPMessage {
  struct Parser {
    enum Status {
      case incomplete
      case complete(HTTPMessage, unconsumed: Data)
      case invalid
    }

    private enum State {
      case start
      case headers
      case contentWithLength
      case chunkLength
      case chunkData
      case unboundedContent
      case complete
      case invalid
    }

    private var state: State = .start
    private var message: HTTPMessage?
    private var currentLine = Data()
    private var lastHeaderName: String?
    private var lastHeaderValue: String = ""
    private var remainingLength = 0

    init() {
      currentLine.reserveCapacity(128)
    }

    mutating func append(_ data: Data?) -> Status {
      guard let data = data else {
        if state == .unboundedContent {
          state = .complete
          return .complete(message!, unconsumed: Data())
        }
        return .incomplete
      }
      var index = data.startIndex
      while index != data.endIndex {
        let c = data[index]
        switch state {
          case .start, .headers, .chunkLength:
            if c == .lf {
              parseLine()
              currentLine.removeAll()
            } else if c != .cr {
              currentLine.append(c)
            }
          case .contentWithLength, .chunkData:
            // TODO: process more than a byte at a time here
            message!.content!.append(c)
            remainingLength -= 1
            if remainingLength == 0 {
              state = state == .contentWithLength ? .complete : .chunkLength
            }
          case .unboundedContent:
            // TODO: process more than a byte at a time here
            message!.content!.append(c)

          case .invalid:
            return .invalid

          case .complete:
            return .complete(message!, unconsumed: data[index...])
        }
        index += 1
      }
      switch state {
        case .invalid:
          return .invalid
        case .complete:
          return .complete(message!, unconsumed: Data())
        default:
          return .incomplete
      }
    }

    private mutating func parseLine()
    {
      switch state {
        case .start:
          if !currentLine.isEmpty {
            parseRequestOrStatusLine()
          }

        case .headers:
          if currentLine.isEmpty {
            commitLastHeader()
            headersComplete()
            return
          }
          if (currentLine[0].isWhitespace) {
            // Handle deprecated HTTP header folding.
            guard lastHeaderName != nil else {
              state = .invalid
              return
            }
            lastHeaderValue += " " + String(bytes: currentLine.trimmingWhitespace(), encoding: .isoLatin1)!
          }
          commitLastHeader()
          let fields = currentLine.split(separator: .colon, maxSplits: 1)
          guard fields.count == 2 else {
            state = .invalid
            return
          }
          guard let name = String(bytes: fields[0].trimmingWhitespace(), encoding: .isoLatin1) else {
            state = .invalid
            return
          }
          lastHeaderName = name
          lastHeaderValue = String(bytes: fields[1].trimmingWhitespace(), encoding: .isoLatin1)!

        case .chunkLength:
          if currentLine.isEmpty {
            return
          }
          guard let length = Int(String(bytes: currentLine, encoding: .isoLatin1)!, radix: 16) else {
            state = .invalid
            return
          }
          if length == 0 {
            state = .complete
            return
          }
          remainingLength = length
          state = .chunkData

        default:
          fatalError("Internal error")
      }
    }

    private mutating func headersComplete() {
      if let status = message!.status {
        if !status.allowsContent {
          state = .complete
          return
        }
      }

      // Handle the case where we received a `Content-Length` header.
      if let contentLength = message!.contentLength {
        if contentLength == 0 {
          state = .complete
          return
        }
        state = .contentWithLength
        remainingLength = contentLength
        message!.content = Data(capacity: remainingLength)
        return
      }

      // Handle the case where we received a `Transfer-Encoding` header that included `chunked`.
      if message!.transferEncoding.contains(.init(token: "chunked")) {
        state = .chunkLength
        message!.content = Data(capacity: 1024)
        return
      }

      // If the message is a request, the absence of one of the above headers indicates no content.
      if message!.kind == .request {
        state = .complete
        return
      }

      // All that's left is assuming everything is content until the connection is closed.
      message!.content = Data(capacity: 1024)
      state = .unboundedContent
    }

    private mutating func parseRequestOrStatusLine() {
      guard let line = String(bytes: currentLine, encoding: .isoLatin1) else {
        state = .invalid
        return
      }
      let fields = line.split(separator: " ", maxSplits: 2).map { String($0) }
      guard !fields.isEmpty else {
        state = .invalid
        return
      }
      if let version = parseHTTPVersion(fields[0]) {
        // It's a response.
        guard fields.count == 2 || fields.count == 3 else {
          state = .invalid
          return
        }
        guard let statusCode = Int(fields[1]) else {
          state = .invalid
          return
        }
        let reason = fields.count == 3 ? fields[2].trimmingCharacters(in: .whitespaces) : ""
        message = HTTPMessage(status: .init(rawValue: statusCode), reason: reason, version: version)
        state = .headers
        return
      }

      // It's a request
      guard fields.count == 3 else {
        state = .invalid
        return
      }
      let method = fields[0]
      let target = fields[1]
      guard let version = parseHTTPVersion(fields[2]) else {
        state = .invalid
        return
      }
      message = HTTPMessage(method: .init(rawValue: method), target: target, version: version)
      state = .headers
    }

    private func parseHTTPVersion(_ input: String) -> String? {
      let proto = ProtocolIdentifier(input)
      guard proto.name == "HTTP" else {
        return nil
      }
      return proto.version
    }

    private mutating func commitLastHeader() {
      guard let name = lastHeaderName else {
        return
      }
      lastHeaderName = nil
      message!.addHeader(of: name, value: lastHeaderValue)
    }
  }
}

// MARK: ParameterizedToken

struct ParameterizedToken: Equatable {
  let token: String
  private var parameters: [String: String] = [:]

  init(token: String) {
    self.token = token.lowercased()
  }

  mutating func set(parameter name: String, to value: String?) {
    parameters[name.lowercased()] = value
  }

  func get(parameter name: String) -> String? {
    return parameters[name.lowercased()]
  }

  func format() -> String {
    var result = ""
    result.append(token)
    for (key, value) in parameters {
      result += ";\(key)="
      switch TokenFormat.analyze(value) {
        case .bare:
          result += value
        case .quoted:
          result += "\"" + value + "\""
        case .quotedAndEscaped:
          result += "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
      }
    }
    return result
  }

  static func parse(from input: String) -> ParameterizedToken? {
    var parser = Parser(from: input)
    return parser.parse()
  }

  static func parseList(from input: String) -> [ParameterizedToken] {
    var parser = Parser(from: input)
    return parser.parseList()
  }

  private enum TokenFormat {
    case bare
    case quoted
    case quotedAndEscaped

    static func analyze(_ text: String) -> TokenFormat {
      if text.isEmpty {
        return .quoted
      }
      var format: TokenFormat = .bare
      for c in text {
        if (c == "\"") {
          return .quotedAndEscaped
        }
        if !c.isToken {
          format = .quoted
        }
      }
      return format
    }
  }

  private struct Parser {
    let input: Data
    var pos = 0

    init(from input: String) {
      self.input = input.data(using: .utf8)!
    }

    mutating func parseList() -> [ParameterizedToken] {
      var items: [ParameterizedToken] = []
      repeat {
        guard let item = parse() else {
          break
        }
        items.append(item)
      } while maybe(.comma)
      return items
    }

    mutating func parse() -> ParameterizedToken? {
      guard let token = nextToken() else {
        return nil
      }
      var result = ParameterizedToken(token: token)
      while maybe(.semicolon) {
        guard let name = nextToken() else {
          break
        }
        if maybe(.eq), let value = nextToken() ?? quotedText() {
          result.set(parameter: name, to: value)
        } else {
          result.set(parameter: name, to: "")
        }
      }
      return result
    }

    private mutating func nextToken() -> String? {
      skipWhitespace()
      let start = pos
      while pos != input.count && (input[pos] == .slash || input[pos].isToken) {
        pos += 1
      }
      guard start != pos else {
        return nil
      }
      return String(data: input[start..<pos], encoding: .isoLatin1)!
    }

    private mutating func quotedText() -> String? {
      skipWhitespace()
      let start = pos
      guard pos != input.count && input[pos] == .quote else {
        return nil
      }
      pos += 1
      var data = Data(capacity: 64)
      while pos != input.count {
        switch input[pos] {
          case .quote:
            pos += 1
            return String(data: data, encoding: .isoLatin1)
          case .backslash:
            pos += 1
            guard pos != input.count else {
              pos = start
              return nil
            }
            fallthrough
          default:
            data.append(input[pos])
            pos += 1
        }
      }
      pos = start
      return nil
    }

    @discardableResult
    private mutating func maybe(_ c: UInt8) -> Bool {
      skipWhitespace()
      if pos != input.count && input[pos] == c {
        pos += 1
        return true
      }
      return false
    }

    private mutating func skipWhitespace() {
      while pos != input.count && input[pos].isWhitespace {
        pos += 1
      }
    }
  }
}

// MARK: ProtocolIdentifier

internal struct ProtocolIdentifier: LosslessStringConvertible {
  let name: String
  let version: String?

  var description: String {
    if let version = version {
      return "\(name)/\(version)"
    }
    return name;
  }

  init(name: String, version: String? = nil) {
    self.name = name
    self.version = version
  }

  init(_ input: String) {
    let input = input.trimmingCharacters(in: .whitespaces)
    let fields = input.split(separator: "/").map { String($0) }
    if fields.count < 2 {
      name = input
      version = nil
    } else {
      name = fields[0]
      version = fields[1]
    }
  }
}

extension ProtocolIdentifier : Equatable {
  static func == (lhs: ProtocolIdentifier, rhs: ProtocolIdentifier) -> Bool {
    if lhs.name.lowercased() != rhs.name.lowercased() {
      return false
    }
    return lhs.version == rhs.version
  }
}

// MARK: Private Data extension

fileprivate extension Data {
  func trimmingWhitespace() -> Data {
    let start = self.firstIndex { !$0.isWhitespace } ?? 0
    let end = (self.lastIndex { !$0.isWhitespace } ?? self.count - 1) + 1
    return self[start..<end]
  }
}

// MARK: Private UInt8 and Character extensions

fileprivate extension UInt8 {
  static let tab: UInt8 = 0x09
  static let lf: UInt8 = 0x0a
  static let cr: UInt8 = 0x0d
  static let space: UInt8 = 0x20
  static let quote: UInt8 = 0x22
  static let lparen: UInt8 = 0x28
  static let rparen: UInt8 = 0x29
  static let comma: UInt8 = 0x2c
  static let slash: UInt8 = 0x2f
  static let colon: UInt8 = 0x3a
  static let semicolon: UInt8 = 0x3b
  static let lt: UInt8 = 0x3c
  static let eq: UInt8 = 0x3d
  static let gt: UInt8 = 0x3e
  static let question: UInt8 = 0x3f
  static let at: UInt8 = 0x40
  static let lbracket: UInt8 = 0x5b
  static let backslash: UInt8 = 0x5c
  static let rbracket: UInt8 = 0x5d
  static let lbrace: UInt8 = 0x7b
  static let rbrace: UInt8 = 0x7d

  var isWhitespace: Bool {
    return self == .tab || self == .space;
  }

  var isSeparator: Bool {
    return self == .lparen || self == .rparen || self == .lt || self == .gt || self == .at ||
           self == .comma || self == .semicolon || self == .colon || self == .backslash || self == .quote ||
           self == .slash || self == .lbracket || self == .rbracket || self == .question || self == .eq ||
           self == .lbrace || self == .rbrace || self == .space || self == .tab
  }

  var isControl: Bool {
    return self < 0x20 || self == 0x7f
  }

  var isToken: Bool {
    return self < 0x80 && !isSeparator && !isControl
  }
}

fileprivate extension Character {
  var isToken: Bool {
    self.asciiValue?.isToken ?? false
  }
}

fileprivate func isForbiddenHeader(name: String) -> Bool {
  let key = name.lowercased()
  if key.starts(with: "sec-") || key.starts(with: "proxy-") {
    return true
  }
  return key == "connection" || key == "content-length" || key == "expect" || key == "host" ||
         key == "keep-alive" || key == "te" || key == "trailer" || key == "transfer-encoding" ||
         key == "upgrade"
}
