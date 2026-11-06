// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import StreamProtocol

let targets = WakeInterfaces.read()
guard targets.count <= 8,
      targets.allSatisfy({ $0.validAddress && $0.packet?.count == 102 }) else {
    fatalError("Invalid wake target from the system interface list")
}
if ProcessInfo.processInfo.environment["DUO_EXPECT_WAKE_INTERFACE"] == "1", targets.isEmpty {
    fatalError("No wake target found on this Mac's active Ethernet/Wi-Fi interfaces")
}
print("Wake interface check passed: \(targets.count) local targets; addresses not printed")
