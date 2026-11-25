import Foundation
import dnssd

struct LANDiscovery: Codable, Equatable, Sendable {
    let enabled: Bool
    var status: String
    var mdnsUrl: String?
    var ipUrl: String?

    var preferredUrl: String? { mdnsUrl ?? ipUrl }
}

@MainActor
final class LANDiscoveryPublisher {
    private var hostRecord: DNSServiceRef?
    private var service: DNSServiceRef?
    private var timeout: Task<Void, Never>?
    private var result: ((Bool) -> Void)?
    private var generation = 0

    func start(label: String, address: Data, interface: UInt32, port: UInt16, result: @escaping (Bool) -> Void) {
        stop()
        self.result = result
        let host = label + ".local."
        guard DNSServiceCreateConnection(&hostRecord) == kDNSServiceErr_NoError, let hostRecord else {
            failed()
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var record: DNSRecordRef?
        let status = address.withUnsafeBytes { data in
            DNSServiceRegisterRecord(hostRecord, &record, DNSServiceFlags(kDNSServiceFlagsUnique), interface,
                                     host, UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                                     UInt16(data.count), data.baseAddress, 120, { ref, _, _, error, context in
                guard let ref, let context else { return }
                let owner = Unmanaged<LANDiscoveryPublisher>.fromOpaque(context).takeUnretainedValue()
                let id = UInt(bitPattern: ref)
                let generation = MainActor.assumeIsolated { owner.generation }
                Task { @MainActor [weak owner] in
                    guard let owner, owner.generation == generation else { return }
                    owner.hostRegistered(id: id, error: error)
                }
            }, context)
        }
        guard status == kDNSServiceErr_NoError,
              DNSServiceSetDispatchQueue(hostRecord, .main) == kDNSServiceErr_NoError else {
            failed()
            return
        }
        pending = (label, host, interface, port)
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            self?.failed()
        }
    }

    private var pending: (label: String, host: String, interface: UInt32, port: UInt16)?

    private func hostRegistered(id: UInt, error: DNSServiceErrorType) {
        guard let hostRecord, UInt(bitPattern: hostRecord) == id else { return }
        guard error == kDNSServiceErr_NoError else { failed(); return }
        guard service == nil, let pending else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = DNSServiceRegister(&service, DNSServiceFlags(kDNSServiceFlagsNoAutoRename), pending.interface,
                                        pending.label, "_http._tcp", "local.", pending.host, pending.port.bigEndian,
                                        0, nil, { ref, flags, error, _, _, _, context in
            guard let ref, let context else { return }
            let owner = Unmanaged<LANDiscoveryPublisher>.fromOpaque(context).takeUnretainedValue()
            let id = UInt(bitPattern: ref)
            let generation = MainActor.assumeIsolated { owner.generation }
            Task { @MainActor [weak owner] in
                guard let owner, owner.generation == generation else { return }
                owner.serviceRegistered(id: id, added: flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, error: error)
            }
        }, context)
        guard status == kDNSServiceErr_NoError, let service,
              DNSServiceSetDispatchQueue(service, .main) == kDNSServiceErr_NoError else {
            failed()
            return
        }
    }

    private func serviceRegistered(id: UInt, added: Bool, error: DNSServiceErrorType) {
        guard let service, UInt(bitPattern: service) == id else { return }
        guard added, error == kDNSServiceErr_NoError else { failed(); return }
        timeout?.cancel()
        result?(true)
    }

    private func failed() {
        let callback = result
        stop()
        callback?(false)
    }

    func stop() {
        generation &+= 1
        timeout?.cancel()
        timeout = nil
        result = nil
        pending = nil
        if let service { DNSServiceRefDeallocate(service) }
        service = nil
        if let hostRecord { DNSServiceRefDeallocate(hostRecord) }
        hostRecord = nil
    }
}
