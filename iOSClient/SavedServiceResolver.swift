import Foundation
import dnssd

/// One bounded lookup of a previously paired Bonjour service. All operations run on the main queue.
final class SavedServiceResolver {
    struct Answer {
        let tag: String
        let interfaceIndex: UInt32
    }

    private var ref: DNSServiceRef?
    private var timeout: DispatchWorkItem?
    private var completion: ((Answer?) -> Void)?
    private var acceptsTag: ((String) -> Bool)?

    func start(name: String, type: String, acceptsTag: @escaping (String) -> Bool,
               completion: @escaping (Answer?) -> Void) {
        self.completion = completion
        self.acceptsTag = acceptsTag
        var service: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        var fullName = [CChar](repeating: 0, count: Int(kDNSServiceMaxDomainName))
        guard DNSServiceConstructFullName(&fullName, name, type, "local.") == kDNSServiceErr_NoError else {
            finish(nil)
            return
        }
        // Query the recognition record explicitly on multicast. A cached PTR browse can miss a
        // host after reboot; Resolve alone may return an old TXT before its replacement arrives.
        let result = DNSServiceQueryRecord(&service, DNSServiceFlags(kDNSServiceFlagsForceMulticast), 0,
                                           fullName, UInt16(kDNSServiceType_TXT), UInt16(kDNSServiceClass_IN),
                                           { _, flags, interface, error, _, _, _, length, record, _, context in
            guard let context else { return }
            let resolver = Unmanaged<SavedServiceResolver>.fromOpaque(context).takeUnretainedValue()
            guard error == kDNSServiceErr_NoError else { resolver.finish(nil); return }
            guard flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 else { return }
            var tagLength: UInt8 = 0
            let value = record.flatMap { TXTRecordGetValuePtr(length, $0, "r", &tagLength) }
            let tag = value.flatMap { String(data: Data(bytes: $0, count: Int(tagLength)), encoding: .utf8) }
            guard let tag, resolver.acceptsTag?(tag) == true else { return }
            resolver.finish(Answer(tag: tag, interfaceIndex: interface))
        }, context)
        guard result == kDNSServiceErr_NoError, let service else { finish(nil); return }
        ref = service
        guard DNSServiceSetDispatchQueue(service, .main) == kDNSServiceErr_NoError else { finish(nil); return }
        let work = DispatchWorkItem { [weak self] in self?.finish(nil) }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func cancel() {
        completion = nil
        acceptsTag = nil
        timeout?.cancel()
        timeout = nil
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
    }

    private func finish(_ answer: Answer?) {
        let callback = completion
        cancel()
        callback?(answer)
    }

    deinit { cancel() }
}
