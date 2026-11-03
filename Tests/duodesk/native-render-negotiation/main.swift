// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import StreamProtocol

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let metrics = DuoNativeDisplayMetrics(pixels: CGSize(width: 1878, height: 2670),
                                     windowSize: CGSize(width: 669, height: 951),
                                     renderPixels: CGSize(width: 2007, height: 2853))
let legacy = DuoDesktopResolution(width: 1878, height: 1335)
let rendered = DuoDesktopResolution(width: 2007, height: 1427)
check(DuoStreamPolicy.upperDisplay(metrics: metrics, renderedRequired: false) == legacy,
      "a legacy host keeps the established physical-pixel mirror request")
check(DuoStreamPolicy.upperDisplay(metrics: metrics, renderedRequired: true) == rendered,
      "a capable host gets the full render-pixel upper display")
check(rendered.encodedWidth == 2008 && rendered.encodedHeight == 1428,
      "odd upper-display pixels round up for the encoder")
var rotated = metrics
rotated.pixels = CGSize(width: 2670, height: 1878)
rotated.renderPixels = CGSize(width: 2853, height: 2007)
check(DuoStreamPolicy.upperDisplay(metrics: rotated, renderedRequired: true) == rendered,
      "rotating both reported sizes does not reduce an axis")
var mixed = metrics
mixed.renderPixels = CGSize(width: 1800, height: 2800)
check(DuoStreamPolicy.upperDisplay(metrics: mixed, renderedRequired: true) == nil,
      "incompatible axes cannot be combined into a different desktop aspect")
var wrongAspect = metrics
wrongAspect.renderPixels = CGSize(width: 2200, height: 3500)
check(DuoStreamPolicy.upperDisplay(metrics: wrongAspect, renderedRequired: true) == nil,
      "a larger but differently shaped render canvas is rejected")
var physicalLarger = metrics
physicalLarger.pixels = CGSize(width: 2007, height: 2853)
physicalLarger.renderPixels = CGSize(width: 1878, height: 2670)
check(DuoStreamPolicy.upperDisplay(metrics: physicalLarger, renderedRequired: true) == rendered,
      "a larger physical canvas is kept in full")
var crossing = metrics
crossing.pixels = CGSize(width: 2000, height: 3000)
crossing.renderPixels = CGSize(width: 2001, height: 2999)
check(DuoStreamPolicy.upperDisplay(metrics: crossing, renderedRequired: true) == nil,
      "crossing dimensions cannot be mixed even when their aspects nearly agree")
var missing = metrics
missing.renderPixels = nil
check(DuoStreamPolicy.upperDisplay(metrics: missing, renderedRequired: true) == nil,
      "a strict request does not substitute physical pixels for an unknown render canvas")
var invalid = metrics
invalid.renderPixels = CGSize(width: CGFloat.nan, height: 2853)
check(DuoStreamPolicy.upperDisplay(metrics: invalid, renderedRequired: true) == nil,
      "invalid render dimensions cannot become a smaller strict request")

let suite = "duodesk.tests.native-render.\(UUID().uuidString)"
guard let defaults = UserDefaults(suiteName: suite) else { fatalError("isolated defaults unavailable") }
defer { defaults.removePersistentDomain(forName: suite) }
defaults.set(try JSONEncoder().encode(legacy), forKey: DuoStreamPolicy.legacyUpperDisplayKey)
check(DuoStreamPolicy.cachedUpperDisplay(in: defaults, rendered: false) == legacy,
      "the legacy cache remains readable")
check(DuoStreamPolicy.cachedUpperDisplay(in: defaults, rendered: true) == nil,
      "a smaller legacy cache cannot stand in for render pixels")
defaults.set(try JSONEncoder().encode(rendered), forKey: DuoStreamPolicy.renderedUpperDisplayKey)
check(DuoStreamPolicy.cachedUpperDisplay(in: defaults, rendered: true) == rendered
      && DuoStreamPolicy.cachedUpperDisplay(in: defaults, rendered: false) == legacy,
      "the two host generations have independent caches")
defaults.set(Data("invalid".utf8), forKey: DuoStreamPolicy.renderedUpperDisplayKey)
check(DuoStreamPolicy.cachedUpperDisplay(in: defaults, rendered: true) == nil,
      "a corrupt strict cache cannot authorize a request")
print("Native render sizing: 14 checks passed; no screen or network was used")
