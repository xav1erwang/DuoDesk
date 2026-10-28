// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Writes only an in-memory test image. It never captures a screen or requests permissions.
import CoreGraphics
import Darwin
import Foundation
import ImageIO

guard (2...3).contains(CommandLine.arguments.count) else { exit(1) }
let path = CommandLine.arguments[1]
let directory = (path as NSString).deletingLastPathComponent
var info = stat()
guard lstat(directory, &info) == 0, info.st_uid == geteuid(),
      info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { exit(2) }

var pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255]
let success = pixels.withUnsafeMutableBytes { bytes -> Bool in
    guard let context = CGContext(data: bytes.baseAddress, width: 4, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                             "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}
guard success else { exit(3) }
if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--hold" { usleep(750_000) }
