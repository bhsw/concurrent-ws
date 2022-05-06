// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation

/// The content type of an HTTP response body.
public struct ContentType {
  /// The media type (e.g. `text/plain`).
  public let mediaType: String

  /// The character set (e.g. `UTF-8`) used if the content is text.
  public let charset: String?

  /// Initializes a `ContentType`.
  public init(mediaType: String, charset: String? = nil) {
    self.mediaType = mediaType
    self.charset = charset
  }
  init?(from token: ParameterizedToken?) {
    guard let token = token else {
      return nil
    }
    mediaType = token.token
    charset = token.get(parameter: "charset")
  }
}
