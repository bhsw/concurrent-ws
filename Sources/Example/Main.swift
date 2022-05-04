import Foundation
import WebSockets

@main
struct App {
  static func main() async {
    do {
      try await testClient()
    } catch {
      print("ERROR:", error)
    }
  }

  static func testClient() async throws {
//    let url = URL(string: "ws://europa.ocsoft.net:8080/test")!
//    let url = URL(string: "ws://light.ocsoft.net/api/logs")!
//    let url = URL(string: "wss://m.ocsoft.com/api/logs")!
    let url = URL(string: "wss://echo.websocket.events")!
//    let url = URL(string: "wss://blob.ocsoft.com/redirect-test")!
    var options = WebSocket.Options()
    options.closeAcknowledgementTimeout = 3
    options.connectTimeout = 5
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
    } catch {
      print("ERROR: \(error)")
    }

    await t.value
  }
}
