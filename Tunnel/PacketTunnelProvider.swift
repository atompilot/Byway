import Foundation
import Libbox
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let runtime = TunnelRuntime()

    override func startTunnel(options: [String: NSObject]?) async throws {
        let store = try ProfileStore.open()
        var profile = try store.read()
        if let active = store.activeNodeID(), profile.nodes.contains(where: { $0.id == active }) {
            profile.selectedID = active
        }
        try await runtime.start(profile: profile, store: store, provider: self)
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        await runtime.stop()
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        await runtime.handleMessage(messageData)
    }
}
