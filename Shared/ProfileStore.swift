import Foundation

struct ProfileStore: Sendable {
    let directory: URL

    static func open() throws -> Self {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "BywayAppGroup") as? String,
              let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw BywayError.message("无法访问 Byway 的共享配置，请检查签名")
        }
        return Self(directory: folder)
    }

    private var file: URL { directory.appending(path: "profile.json") }

    func read() throws -> BywayProfile {
        do {
            return try JSONDecoder().decode(BywayProfile.self, from: Data(contentsOf: file))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            error.code == NSFileReadNoSuchFileError {
            return BywayProfile()
        }
    }

    func save(_ profile: BywayProfile) throws {
        try JSONEncoder().encode(profile).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func removePrivateIdentity(_ id: UUID) {
        let identity = directory.appending(path: "private-network/\(id.uuidString)")
        try? FileManager.default.removeItem(at: identity)
    }

    func activeNodeID() -> UUID? {
        let url = directory.appending(path: "selected-node")
        guard let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return UUID(uuidString: value)
    }

    func saveActiveNode(_ id: UUID) throws {
        let url = directory.appending(path: "selected-node")
        try Data(id.uuidString.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func readDeviceName() throws -> String? {
        try readSharedFile(String.self, named: "device-name.json")
    }

    func saveDeviceName(_ name: String) throws {
        try writeSharedFile(name, named: "device-name.json")
    }

    func readLANSettings() throws -> LANSettings? {
        try readSharedFile(LANSettings.self, named: "lan-control.json")
    }

    func saveLANSettings(_ settings: LANSettings?) throws {
        try writeSharedFile(settings, named: "lan-control.json")
    }

    func readDiscoveryEnabled() throws -> Bool {
        try readSharedFile(Bool.self, named: "lan-discovery.json") ?? true
    }

    func saveDiscoveryEnabled(_ enabled: Bool) throws {
        try writeSharedFile(enabled, named: "lan-discovery.json")
    }

    func readLANEndpoint() throws -> LANPublishedEndpoint? {
        try readSharedFile(LANPublishedEndpoint.self, named: "lan-endpoint.json")
    }

    func saveLANEndpoint(_ endpoint: LANPublishedEndpoint?) throws {
        try writeSharedFile(endpoint, named: "lan-endpoint.json")
    }

    func readTrafficTotal() throws -> TrafficBytes {
        try readTrafficHistory().lifetime
    }

    func readTrafficHistory() throws -> TrafficHistory {
        if let history = try readSharedFile(TrafficHistory.self, named: "traffic-history.json") { return history }
        return TrafficHistory(lifetime: try readSharedFile(TrafficBytes.self, named: "traffic.json") ?? TrafficBytes())
    }

    func saveTrafficHistory(_ history: TrafficHistory) throws {
        try writeSharedFile(history, named: "traffic-history.json")
    }

    func readLANCalls() throws -> [LANCall] {
        try readSharedFile([LANCall].self, named: "lan-calls.json") ?? []
    }

    func appendLANCall(_ call: LANCall) throws {
        var calls = try readLANCalls()
        calls.append(call)
        try writeSharedFile(Array(calls.suffix(200)), named: "lan-calls.json")
    }

    func readRoutingNetwork() throws -> RoutingNetwork? {
        try readSharedFile(RoutingNetwork.self, named: "routing-network.json")
    }

    func saveRoutingNetwork(_ network: RoutingNetwork?) throws {
        try writeSharedFile(network, named: "routing-network.json")
    }

    private func readSharedFile<T: Decodable>(_ type: T.Type, named name: String) throws -> T? {
        do {
            return try JSONDecoder().decode(T?.self, from: Data(contentsOf: directory.appending(path: name)))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    private func writeSharedFile(_ value: (some Encodable)?, named name: String) throws {
        try JSONEncoder().encode(value).write(to: directory.appending(path: name),
                                              options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
