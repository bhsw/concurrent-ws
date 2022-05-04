import Foundation
@testable import WebSockets

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
    let url = URL(string: "wss://m.ocsoft.com/api/logs")!
//    let url = URL(string: "wss://echo.websocket.events")!
//    let url = URL(string: "wss://blob.ocsoft.com/redirect-test")!
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
      print("STATUS:", result.statusCode)
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
    let options = WebSocket.Options()
    let listener = Listener(port: 80, tls: false, options: options)
    Task {
      try await Task.sleep(nanoseconds: 100_000_000_000)
      listener.stop()
    }
    for try await event in listener {
      switch event {
        case .ready:
          print("* Listener ready")
        case .networkUnavailable:
          print("* Listener reports network unavailable")
        case .connection(let connection):
          Task {
            print("* Got a client")
            for try await event in connection {
              switch event {
                case .connect:
                  print("* Client connect event")
                case .receive(let data):
                  if let data = data {
                    print("RECEIVE:", data)
                  } else {
                    print("END")
                  }
                default:
                  break
              }
            }
          }
      }
    }
  }
}
