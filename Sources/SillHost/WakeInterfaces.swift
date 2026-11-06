// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import StreamProtocol

enum WakeInterfaces {
    /// Only active Ethernet/Wi-Fi interfaces, never VPN or peer-to-peer interfaces.
    static func read() -> [WakeTarget] {
        var hardware: [String: String] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, Int32(sa.pointee.sa_family) == AF_LINK,
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_RUNNING) != 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let link = sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
            guard link.sdl_type == 6, link.sdl_alen == 6 else { continue }
            let bytes = withUnsafeBytes(of: link.sdl_data) { Array($0) }
            let offset = Int(link.sdl_nlen)
            guard offset + 6 <= bytes.count else { continue }
            hardware[name] = bytes[offset..<(offset + 6)].map { String(format: "%02x", $0) }.joined(separator: ":")
        }
        return Array(InterfaceSnapshot.shared.entries().compactMap { entry -> WakeTarget? in
            guard entry.up, !entry.pointToPoint, !entry.loopback, entry.address.count == 4,
                  let mac = hardware[entry.name] else { return nil }
            let target = WakeTarget(address: IPBytes.text(entry.address), hardwareAddress: mac)
            return target.validAddress && target.packet != nil ? target : nil
        }.prefix(8))
    }
}
