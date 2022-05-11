// SPDX-License-Identifier: MIT
// Copyright 2022 Robert A. Stoerrle

import Foundation

func randomData(size: Int) -> Data {
  // It's much faster for larger sizes to set up an array first and then initialize a `Data` instance.
  // For some reason, subscripting and appending to data is very slow compared to a UInt8 array.
  var bytes: [UInt8] = []
  bytes.reserveCapacity(size)
  var index = 0
  while index < size {
    bytes.append(UInt8.random(in: 0...255))
    index &+= 1
  }
  return Data(bytes)
}
