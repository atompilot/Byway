import Foundation
import Network

@main
struct Fixture {
    @MainActor
    static func main() async throws {
        let store = ProfileStore(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
        let role = CommandLine.arguments[2]
        let deviceFile = store.directory.appending(path: "fixture-device-id")
        if role == "enable" {
            if !FileManager.default.fileExists(atPath: deviceFile.path) {
                try Data(UUID().uuidString.utf8).write(to: deviceFile, options: .atomic)
            }
            try store.saveLANSettings(LANSettings())
            return
        }
        if role == "disable" {
            try store.saveLANSettings(nil)
            return
        }

        let port = NWEndpoint.Port(rawValue: UInt16(CommandLine.arguments[3])!)!
        let server = LANServer(port: port)
        let backend = FixtureBackend(store: store, connected: role == "vpn")
        func refresh() async throws {
            if let settings = try store.readLANSettings() {
                server.start(settings, store: store) { _ in } handle: { request in
                    await LANAPI(backend: backend, deviceStore: {
                        DeviceIdentityStore(profile: store, type: "iphone", defaultName: "iPhone",
                                            modelIdentifier: "iPhone15,3", appVersion: "0.1.0",
                                            deviceID: {
                                                guard let id = UUID(uuidString: try String(contentsOf: deviceFile, encoding: .utf8)) else {
                                                    throw LANFailure(503, "Invalid fixture device ID")
                                                }
                                                return id
                                            })
                    }).handle(request)
                }
            } else {
                server.stop()
            }
        }
        try await refresh()
        for try await line in FileHandle.standardInput.bytes.lines {
            switch line {
            case "refresh": try await refresh()
            case "stop": server.stop()
            default: break
            }
        }
        server.endSession()
    }
}

actor FixtureBackend: LANBackend {
    let store: ProfileStore
    let connected: Bool
    init(store: ProfileStore, connected: Bool) {
        self.store = store
        self.connected = connected
    }

    func lanSnapshot() async throws -> LANSnapshot {
        let profile = try store.read()
        let preferred = store.activeNodeID()
        let active = profile.nodes.first { $0.id == preferred } ?? profile.selected
        return LANSnapshot(connected: connected, activeID: active?.id, profile: profile)
    }

    func lanEdit(_ edit: LANEdit) async throws -> LANEditReceipt {
        let profile = try store.read()
        let (updated, result) = try edit.applying(to: profile, activeID: store.activeNodeID())
        try store.save(updated)
        return result
    }

    func lanPrivateChange(_ change: PrivateNetworkChange) async throws -> PrivateNetworkReceipt {
        var profile = try store.read()
        profile.privateNetwork = try change.applying(to: profile.privateNetwork)
        try store.save(profile)
        return PrivateNetworkReceipt(status: PrivateNetworkSettingsView(profile.privateNetwork))
    }

    func lanNodeCommand(_ operation: Operation, id: UUID) async throws -> CommandResult {
        let profile = try store.read()
        guard profile.nodes.contains(where: { $0.id == id }) else { throw LANFailure.nodeNotFound }
        if operation == .select { try store.saveActiveNode(id) }
        let status = TunnelStatus(connected: connected, selectedNodeID: store.activeNodeID(),
                                  nodes: profile.nodes.map { NodeStatus(id: $0.id, name: $0.name) })
        return CommandResult(id: UUID(), status: status, probe: nil, error: nil)
    }
}
