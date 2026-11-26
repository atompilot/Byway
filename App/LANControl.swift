import Foundation

@MainActor
final class LANControl: ObservableObject {
    @Published private var settings: LANSettings?
    @Published private var endpoint = LANEndpoint.off

    private let server = LANServer()
    private var store: ProfileStore?
    private var foreground = false

    var enabled: Bool { settings != nil }
    var address: String? { endpoint.address }
    var state: String { endpoint.state }
    var discovery: LANDiscovery? { endpoint.discovery }
    var discoveryEnabled: Bool { endpoint.discovery?.enabled ?? ((try? store?.readDiscoveryEnabled()) ?? true) }

    func setDiscoveryEnabled(_ enabled: Bool, vpn: VPNController) {
        guard self.enabled else { return }
        do {
            try accessStore().saveDiscoveryEnabled(enabled)
            refresh(vpn: vpn)
            if vpn.connected {
                Task { [weak self, weak vpn] in
                    guard let self, let vpn else { return }
                    do {
                        try await vpn.refreshTunnelLAN()
                        self.refresh(vpn: vpn)
                    } catch {
                        vpn.message = error.localizedDescription
                    }
                }
            }
        } catch {
            vpn.message = error.localizedDescription
        }
    }
    var token: String { settings?.token ?? "" }

    func setForeground(_ value: Bool, vpn: VPNController) {
        foreground = value
        refresh(vpn: vpn)
    }

    func setEnabled(_ value: Bool, vpn: VPNController) {
        guard vpn.ready, foreground, value != enabled else { return }
        do {
            let store = try accessStore()
            let desired = value ? LANSettings() : nil
            try store.saveLANSettings(desired)
            settings = desired
            refresh(vpn: vpn)
            if vpn.connected {
                Task { [weak self, weak vpn] in
                    guard let self, let vpn else { return }
                    do {
                        try await vpn.refreshTunnelLAN()
                        self.refresh(vpn: vpn)
                    } catch {
                        guard self.settings == desired, desired != nil else { return }
                        self.endpoint = LANEndpoint(state: L10n.text("VPN 未应答，请检查连接状态"))
                    }
                }
            }
        } catch {
            vpn.message = error.localizedDescription
        }
    }

    func refresh(vpn: VPNController) {
        guard vpn.ready else {
            server.stop()
            return
        }
        do {
            let store = try accessStore()
            let current = try store.readLANSettings()
            if settings != current { settings = current }
            guard let settings else {
                server.stop()
                endpoint = .off
                return
            }

            if vpn.canHostLAN && foreground {
                server.start(settings, store: store) { [weak self] update in
                    self?.endpoint = update
                } handle: { [weak self, weak vpn] request in
                    guard let self, self.foreground, let vpn, vpn.canHostLAN else {
                        return LANResponse(LANFailure(503, L10n.text("局域网控制已暂停")))
                    }
                    return await LANAPI(backend: vpn).handle(request)
                }
                endpoint = server.endpoint
            } else {
                server.stop()
                endpoint = vpn.canHostLAN ? .paused : .handoff
                if vpn.connected, let published = try store.readLANEndpoint(), published.settingsID == settings.id {
                    endpoint = published.endpoint
                }
            }
        } catch {
            server.stop()
            endpoint = LANEndpoint(state: L10n.text("共享配置不可用"))
        }
    }

    private func accessStore() throws -> ProfileStore {
        if let store { return store }
        let store = try ProfileStore.open()
        self.store = store
        return store
    }
}
