// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation
import WebSockets

@main
struct App {
  static func main() async {
    do {
      let socket = WebSocket(url: URL(string: "ws://localhost:8080")!)
      for index in 1...10 {
        await socket.send(text: "Hello, world #\(index)")
      }
      await socket.close()
      for try await event in socket {
        switch event {
          case .open(_):
            print("Successfully opened the WebSocket")
          case .text(let str):
            print("Received text: \(str)")
          case .close(code: let code, reason: _, wasClean: _):
            print("Closed with code: \(code)")
          default:
            print("Miscellaneous event: \(event)")
        }
      }
    } catch {
      print("ERROR:", error)
    }
  }
}
