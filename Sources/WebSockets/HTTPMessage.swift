import Foundation

/// An HTTP request or response, with just enough functionality to support the WebSocket opening handshake.
internal struct HTTPMessage {
  enum Kind {
    case request
    case response
  }

  let kind : Kind
  var version: String
  var method: String?
  var target: String?
  var statusCode: Int?
  var reason: String?
  var host: String?
  var location: String?
  var upgrade: [ProtocolIdentifier] = []
  var connection: [String] = []
  var webSocketKey: String?
  var webSocketProtocol: [String] = []
  var webSocketVersion: [Int] = []
  var webSocketAccept: String?
  var webSocketExtensions: [ExtensionSpecifier] = []
  var extraHeaders: [String: String] = [:]

  init(method: String, target: String, version: String="1.1") {
    self.kind = .request
    self.version = version
    self.method = method
    self.target = target
  }

  init(statusCode: Int, reason: String, version: String="1.1") {
    self.kind = .response
    self.version = version
    self.statusCode = statusCode
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

  mutating func addWebSocketExtension(_ specifier: ExtensionSpecifier) {
    if !webSocketExtensions.contains(specifier) {
      webSocketExtensions.append(specifier)
    }
  }

  mutating func addWebSocketExtension(name: String, parameters: [String: String] = [:]) {
    addWebSocketExtension(.init(name: name, parameters: parameters))
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
      let items = webSocketExtensions.map { ListItem(token: $0.name, parameters: $0.parameters) }
      result += "Sec-WebSocket-Extensions: " + ListFormatter.format(items: items) + "\r\n"
    }
    for (name, value) in extraHeaders {
      result += "\(name): \(value)\r\n"
    }
    result += "\r\n"
    return result
  }

  func encode() -> Data? {
    return headerString.data(using: .isoLatin1)
  }
}

// MARK: Private Implementation

private extension HTTPMessage {
  var firstLine: String {
    switch kind {
      case .request:
        return method! + " " + target! + " HTTP/" + version
      case .response:
        return "HTTP/" + version + " " + String(statusCode!) + " " + reason!
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
        webSocketExtensions += ListParser.parse(input: value)
          .map { ExtensionSpecifier(name: $0.token, parameters: $0.parameters) }
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

    private var message: HTTPMessage?
    private var currentLine = Data()
    private var lastHeaderName: String?
    private var lastHeaderValue: String = ""

    init() {
      currentLine.reserveCapacity(128)
    }

    mutating func append(_ data: Data) -> Status {
      for index in 0..<data.count {
        let octet = data[index]
        switch octet {
          case .cr:
            // Ignore carriage return.
            break;
          case .lf:
            let status = parseLine(unconsumed: data[(index + 1)...])
            currentLine.removeAll()
            if (status != nil) {
              return status!
            }
          default:
            currentLine.append(octet)
        }
      }
      return .incomplete
    }

    private mutating func parseLine(unconsumed: Data) -> Status?
    {
      if currentLine.isEmpty {
        if message != nil{
          commitLastHeader()
          return .complete(message!, unconsumed: unconsumed)
        }
        // Tolerate any number of blank lines before the header line.
        return nil
      }

      if message == nil {
        return parseRequestOrStatusLine()
      }

      if (currentLine[0].isWhitespace) {
        // Handle deprecated HTTP header folding.
        guard lastHeaderName != nil else {
          return .invalid
        }
        lastHeaderValue += " " + String(bytes: currentLine.trimmingWhitespace(), encoding: .isoLatin1)!
        return nil
      }

      commitLastHeader()
      let fields = currentLine.split(separator: .colon, maxSplits: 1)
      guard fields.count == 2 else {
        return .invalid
      }
      guard let name = String(bytes: fields[0].trimmingWhitespace(), encoding: .isoLatin1) else {
        return .invalid
      }
      lastHeaderName = name
      lastHeaderValue = String(bytes: fields[1].trimmingWhitespace(), encoding: .isoLatin1)!
      return nil
    }

    private mutating func parseRequestOrStatusLine() -> Status? {
      guard let line = String(bytes: currentLine, encoding: .isoLatin1) else {
        return .invalid
      }
      let fields = line.split(separator: " ", maxSplits: 2).map { String($0) }
      guard fields.count == 2 || fields.count == 3 else {
        return .invalid
      }

      if let version = parseHTTPVersion(fields[0]) {
        // It's a response.
        guard let statusCode = Int(fields[1]) else {
          return .invalid
        }
        let reason = fields.count == 3 ? fields[2].trimmingCharacters(in: .whitespaces) : ""
        message = HTTPMessage(statusCode: statusCode, reason: reason, version: version)
        return nil
      }

      // It's a request
      let method = fields[0]
      let target = fields[1]
      guard let version = parseHTTPVersion(fields[2]) else {
        return .invalid
      }
      message = HTTPMessage(method: method, target: target, version: version)
      return nil
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

// MARK: Headers with parameters

extension HTTPMessage {
  enum TokenFormat {
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
        if (!c.isToken) {
          format = .quoted
        }
      }
      return format
    }
  }

  struct ListItem {
    let token: String
    let parameters: [String: String]
  }

  struct ListFormatter {
    var output: String = ""

    static func format(items: [ListItem]) -> String {
      var formatter = ListFormatter()
      for item in items {
        formatter.append(item: item)
      }
      return formatter.output
    }

    mutating func append(item: ListItem) {
      guard TokenFormat.analyze(item.token) == .bare else {
        return
      }
      if !output.isEmpty {
        output += ", "
      }
      output.append(item.token)
      for (name, value) in item.parameters {
        guard TokenFormat.analyze(name) == .bare else {
          continue
        }
        output += ";" + name
        append(value: value)
      }
    }

    private mutating func append(value: String) {
      output += "="
      switch TokenFormat.analyze(value) {
        case .bare:
          output += value
        case .quoted:
          output += "\"" + value + "\""
        case .quotedAndEscaped:
          output += "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
      }
    }
  }

  struct ListParser {
    let input: Data
    var pos = 0

    static func parse(input: String) -> [ListItem] {
      var parser = ListParser(from: input.data(using: .utf8)!)
      return parser.parse()
    }

    init(from data: Data) {
      self.input = data
    }

    mutating func parse() -> [ListItem] {
      var items: [ListItem] = []
      repeat {
        guard let item = next() else {
          break
        }
        items.append(item)
      } while maybe(.comma)
      return items
    }

    mutating func next() -> ListItem? {
      guard let token = nextToken() else {
        return nil
      }
      var params: [String: String] = [:]
      while maybe(.semicolon) {
        guard let name = nextToken() else {
          break
        }
        if maybe(.eq), let value = nextToken() ?? quotedText() {
          params[name] = value
        } else {
          params[name] = ""
        }
      }
      return .init(token: token, parameters: params)
    }

    private mutating func nextToken() -> String? {
      skipWhitespace()
      let start = pos
      while pos != input.count && input[pos].isToken {
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

// MARK: ExtensionIdentifier

internal struct ExtensionSpecifier: Equatable {
  let name: String
  let parameters: [String: String]

  init(name: String, parameters: [String: String]) {
    self.name = name
    self.parameters = parameters
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
