import Foundation
import WebSockets

@main
struct App {
  static func main() async {
    do {
//      try await testClient()
      try await testServer()
    } catch {
      print("ERROR:", error)
    }
  }

  static func testClient() async throws {
//    let url = URL(string: "ws://europa.ocsoft.net:8080/testx")!
//    let url = URL(string: "ws://light.ocsoft.net/api/logs")!
//    let url = URL(string: "wss://m.ocsoft.com/api/logs")!
//    let url = URL(string: "wss://echo.websocket.events")!
    let url = URL(string: "wss://blob.ocsoft.com/redirect-test")!
//    let url = URL(string: "wss://github.com")!
    var options = WebSocket.Options()
    options.closingHandshakeTimeout = 3
    options.openingHandshakeTimeout = 1
    let sock = WebSocket(url: url, options: options)
    let t = Task {
      await sock.send(text: "{ \"op\": \"nope\" }")
      print("Sending ping:", await sock.ping(data: "Ping!".data(using: .utf8)!))
      try! await Task.sleep(nanoseconds: 10_000_000_000)
      await sock.close(with: .goingAway, reason: "Going away but this time using a message that is going to be too long to fit in the space provided and will therefore be truncated somewhere")
    }
    do {
      for try await event in sock {
        print("EVENT:", event)
      }
    } catch WebSocket.HandshakeError.unexpectedHTTPStatus(let result) {
      print("STATUS:", result.status)
      if let contentType = result.contentType {
        print("CONTENT-TYPE:", contentType)
        if contentType.mediaType.starts(with: "text/"), let content = result.content {
          print("CONTENT:", String(data: content, encoding: .utf8)!)
        }
      }
    } catch {
      print("ERROR: \(error)")
    }

    await t.value
  }

  static func testServer() async throws {
    let server = WebSocketServer(port: 80)
    Task {
      try await Task.sleep(nanoseconds: 100_000_000_000)
//      listener.stop()
    }
    for try await event in server {
      switch event {
        case .ready:
          print("* Server ready")
        case .networkUnavailable:
          print("* Server reports network unavailable")
        case .client(let client):
          Task {
            do {
              let req = try await client.request()
              print(req)
              if req.method != .get {
                try await client.badRequest()
              } else if req.target == "/portal" {
                try await client.redirect(to: "http://ocsoft.net")
              } else {
                try await client.notFound()
              }
              print("Response sent OK")
            } catch {
              print("Client error:", error)
            }
          }
      }
    }
  }
}
