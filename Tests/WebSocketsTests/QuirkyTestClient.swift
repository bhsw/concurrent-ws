// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation
@testable import WebSockets

actor QuirkyTestClient {
  enum Quirk {
    case none
    case sendUnmasked
    case invalidProtocolVersion
    case invalidHTTPVersion
    case invalidUpgradeHeader
    case invalidConnectionHeader
    case invalidHTTPMethod
    case missingKeyHeader
  }
  let url: URL
  let quirk: Quirk
  let options: WebSocket.Options
  var connection: Connection?
  var inputFramer: InputFramer
  var outputFramer: OutputFramer
  var openEvent: WebSocket.Event?

  init(url: URL, quirk: Quirk = .none, options: WebSocket.Options = .init()) {
    self.url = url
    self.quirk = quirk
    self.options = options
    inputFramer = InputFramer(forClient: true, maximumMessageSize: options.maximumIncomingMessagePayloadSize)
    outputFramer = OutputFramer(forClient: quirk != .sendUnmasked)
  }

  func connect() async throws {
    do {
      guard let scheme = url.scheme?.lowercased(), let host = url.host else {
        throw WebSocketError.invalidURL(url)
      }
      guard scheme == "ws" || scheme == "wss" else {
        throw WebSocketError.invalidURLScheme(scheme)
      }
      let useTLS = scheme == "wss"
      let port = UInt16(url.port ?? (useTLS ? 443 : 80))
      connection = Connection(host: host, port: port, tls: useTLS)
      let handshake = ClientHandshake(options: options)
      for try await event in connection! {
        switch event {
          case .connect:
            var request = handshake.makeRequest(url: url)
            switch quirk {
              case .invalidProtocolVersion:
                request.webSocketVersion = [ 0 ]
              case .invalidHTTPVersion:
                request.version = HTTPVersion(major: 1, minor: 0)
              case .invalidUpgradeHeader:
                request.upgrade = []
              case .invalidConnectionHeader:
                request.connection = []
              case .invalidHTTPMethod:
                request.method = .put
              case .missingKeyHeader:
                request.webSocketKey = nil
              default:
                break
            }
            await connection!.send(data: request.encode())
          case .receive(let data):
            switch try handshake.receive(data: data) {
              case .incomplete:
                continue
              case .ready(result: let result, unconsumed: let unconsumed):
                inputFramer.push(unconsumed)
                openEvent = .open(result)
                return
              case .redirect(_):
                throw WebSocketError.maximumRedirectsExceeded
              }
            default:
              continue
          }
        }
        throw WebSocketError.unexpectedDisconnect
    } catch {
      connection?.close()
      connection = nil
      throw error
    }
  }

  func nextEvent() async -> WebSocket.Event? {
    if let openEvent = openEvent {
      self.openEvent = nil
      return openEvent
    }
    do {
      if let event = await checkForInputFrame() {
        return event
      }
      for try await event in connection! {
        switch event {
          case .receive(let data):
            guard let data = data else {
              break
            }
            inputFramer.push(data)
            if let event = await checkForInputFrame() {
              return event
            }
          default:
            break
        }
      }
      return nil
    } catch {
      return nil
    }
  }

  @discardableResult
  func send(text: String) async -> Bool {
    return await send(frame: .text(text))
  }
  
  @discardableResult
  func send(data: Data) async -> Bool {
    return await send(frame: .binary(data))
  }

  func close(with code: WebSocket.CloseCode = .normalClosure, reason: String = "") async {
    await send(frame: .close(code, reason))
  }

  func disconnect() {
    connection?.close()
  }

  @discardableResult
  private func send(frame: Frame) async -> Bool {
    return await connection?.send(multiple: outputFramer.encode(frame)) ?? false
  }

  private func checkForInputFrame() async -> WebSocket.Event? {
    guard let frame = inputFramer.pop() else {
      return nil
    }
    switch frame {
      case .text(let text):
        return .text(text)
      case .binary(let data):
        return .binary(data)
      case .close(let code, let reason):
        return .close(code: code ?? .noStatusReceived, reason: reason, wasClean: false)
      case .ping(let data):
        return .ping(data)
      case .pong(let data):
        return .pong(data)
      default:
        return nil
    }
  }

}
