// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation

@main
struct App {
  static func main() async {
    let server = EchoServer(on: 8080)
    do {
      try await server.run()
    } catch {
      print("ERROR:", error)
    }
  }
}
