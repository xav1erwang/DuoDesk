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

    func start(name: String, type: String, completion: @escaping (Answer?) -> Void) {
        self.completion = completion
        var service: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = DNSServiceResolve(&service, 0, 0, name, type, "local.", { _, _, interface, error, _, _, port, length, record, context in
            guard let context else { return }
            let resolver = Unmanaged<SavedServiceResolver>.fromOpaque(context).takeUnretainedValue()
            var tagLength: UInt8 = 0
            let value = record.flatMap { TXTRecordGetValuePtr(length, $0, "r", &tagLength) }
            let tag = value.flatMap { String(data: Data(bytes: $0, count: Int(tagLength)), encoding: .utf8) }
            resolver.finish(error == kDNSServiceErr_NoError && port != 0 ? tag.map { Answer(tag: $0, interfaceIndex: interface) } : nil)
        }, context)
        guard result == kDNSServiceErr_NoError, let service else { finish(nil); return }
        ref = service
        guard DNSServiceSetDispatchQueue(service, .main) == kDNSServiceErr_NoError else { finish(nil); return }
        let work = DispatchWorkItem { [weak self] in self?.finish(nil) }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func cancel() {
        completion = nil
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
