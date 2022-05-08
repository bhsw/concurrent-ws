// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation

func randomData(size: Int) -> Data {
  var bytes: [UInt8] = []
  bytes.reserveCapacity(size)
  var index = 0
  while index < size {
    bytes.append(UInt8.random(in: 0...255))
    index += 1
  }
  return Data(bytes)
}
