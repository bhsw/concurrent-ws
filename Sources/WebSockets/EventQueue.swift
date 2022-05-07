// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation

/// An adapter for `AsyncThrowingStream` that makes it easier to use as an asynchronous event queue, particularly inside an actor.
internal class EventQueue<T> {
  typealias StreamType = AsyncThrowingStream<T, Error>

  private var stream: StreamType!
  private var continuation: StreamType.Continuation!
  private var iterator: StreamType.Iterator!

  init() {
    stream = AsyncThrowingStream { continuation in
      self.continuation = continuation
    }
    iterator = stream.makeAsyncIterator()
  }

  /// Adds an event to the queue.
  /// - Parameter event: The event.
  func push(_ event: T) {
    continuation.yield(event)
  }

  /// Indicates that no further events will be added to the queue.
  func finish() {
    continuation.finish()
  }

  /// Indicates that an error occurred, and no further events will be added to the queue.
  func finish(throwing error: Error) {
    continuation.finish(throwing: error)
  }

  /// Returns the next event once it becomes available.
  /// - Returns: The event, or `nil` if there will be no further events because `finish()` was called.
  /// - Throws: If an error was submitted using `finish(throwing:)`.
  func pop() async throws -> T? {
    return try await iterator.next()
  }
}
