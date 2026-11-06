import Foundation
import IOKit.pwr_mgt

/// Wake the display for an authenticated remote session without unlocking the console.
final class RemoteDisplayWake: @unchecked Sendable {
    private let queue = DispatchQueue(label: "duodesk.display-wake", qos: .userInitiated)
    private var assertion = IOPMAssertionID(kIOPMNullAssertionID)
    private var releaseWork: DispatchWorkItem?

    func declareActivity() {
        queue.async { [self] in
            releaseWork?.cancel()
            releaseWork = nil
            let result = IOPMAssertionDeclareUserActivity("DUO你电脑 remote connection" as CFString,
                                                          kIOPMUserActiveRemote, &assertion)
            guard result == kIOReturnSuccess else {
                if assertion != IOPMAssertionID(kIOPMNullAssertionID) { IOPMAssertionRelease(assertion) }
                assertion = IOPMAssertionID(kIOPMNullAssertionID)
                print("Display wake could not be requested: \(result)")
                return
            }
            let work = DispatchWorkItem { [self] in
                if assertion != IOPMAssertionID(kIOPMNullAssertionID) { IOPMAssertionRelease(assertion) }
                assertion = IOPMAssertionID(kIOPMNullAssertionID)
                releaseWork = nil
            }
            releaseWork = work
            queue.asyncAfter(deadline: .now() + 10, execute: work)
        }
    }
}
