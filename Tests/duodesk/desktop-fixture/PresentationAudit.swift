import Foundation
import Metal

/// Counts completed presentation notifications, rather than assuming every draw call appears.
/// Metal invokes these callbacks away from AppKit; the fixture shares only these locked counters.
final class PresentationAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var batchStarted = ProcessInfo.processInfo.systemUptime
    private var lastPresented: Double?
    private var greatestGap = 0.0
    private var knownTimes = 0

    func presented(_ drawable: any MTLDrawable) {
        let now = ProcessInfo.processInfo.systemUptime
        let line: String? = lock.withLock {
            frames += 1
            let time = drawable.presentedTime
            if time > 0 {
                knownTimes += 1
                if let lastPresented, time > lastPresented { greatestGap = max(greatestGap, (time - lastPresented) * 1000) }
                lastPresented = time
            }
            guard frames % 120 == 0 else { return nil }
            let rate = 120 / max(0.000_001, now - batchStarted)
            let line = "Fixture presentation callbacks=\(frames), uptime=\(now), batchFPS=\(rate), knownTimes=\(knownTimes), maxGapMs=\(greatestGap)"
            batchStarted = now; greatestGap = 0; knownTimes = 0
            return line
        }
        if let line { print(line) }
    }
}
