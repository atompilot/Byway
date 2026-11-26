import Foundation
import Libbox
import NetworkExtension

@MainActor
final class VPNController: ObservableObject, LANBackend {
    @Published private(set) var profile = BywayProfile()
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var activeID: UUID?
    @Published private(set) var probes: [UUID: NodeTestResult] = [:]
    @Published private(set) var testingNodeID: UUID?
    @Published private(set) var batchProgress: (completed: Int, total: Int)?
    @Published private(set) var stoppingBatch = false
    @Published private(set) var measuringBandwidth = false
    @Published private(set) var bandwidth: (nodeName: String, result: BandwidthResult)?
    @Published private(set) var bandwidthError: String?
    @Published private(set) var trafficSession: TrafficBytes?
    @Published private(set) var trafficTotal: TrafficBytes?
    @Published private(set) var trafficRates: TrafficBytes?
    @Published private(set) var routingNetwork: RoutingNetwork?
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published private(set) var startingTunnel = false
    @Published var message: String?
    @Published private(set) var privateNetworkSummary: String?

    private var store: ProfileStore?
    #if os(macOS)
    private var engine: (any MacProxyEngine)?
    @Published private(set) var systemProxy: SystemProxy.Mode = .off
    @Published private(set) var takeover: MacTakeover = MacSettings.takeover
    #else
    private var manager: NETunnelProviderManager?
    #endif
    private var observation: (any NSObjectProtocol)?
    private var previousTraffic: (sample: TrafficSnapshot, uptime: TimeInterval)?
    private var batchTask: Task<Void, Never>?
    private var lastPrivateNetworkSummary = Date.distantPast

    enum NodeTestResult {
        case succeeded(Probe)
        case failed
    }

    var connected: Bool { status == .connected || status == .reasserting }
    #if os(macOS)
    var canHostLAN: Bool { ready && !startingTunnel }
    #else
    var canHostLAN: Bool { ready && !startingTunnel && (status == .invalid || status == .disconnected) }
    #endif
    var canEdit: Bool { !busy && canHostLAN }
    var canManage: Bool { canEdit || (!busy && status == .connected) }
    var canTest: Bool { canManage && batchProgress == nil && !measuringBandwidth }
    var canTestBandwidth: Bool { status == .connected && canTest }
    var hasConnectionProfile: Bool { activeNode != nil || connected || profile.privateNetwork?.enabled == true }

    var activeNode: ProxyNode? {
        profile.nodes.first { $0.id == activeID } ?? profile.selected
    }

    var effectiveRouting: RoutingDecision {
        profile.globalRoutingSettings.decision(on: routingNetwork ?? .other)
    }

    var routesDirectly: Bool {
        if profile.nodes.isEmpty, profile.privateNetwork != nil { return true }
        let mode = effectiveRouting.mode
        return mode == .direct || (mode == .rules && profile.importedConfiguration?.enabled != true
                                   && profile.routingSettings.defaultRoute == .direct)
    }

    func canSelectNode(_ node: ProxyNode) -> Bool {
        if !connected, profile.globalRoutingSettings.mode == .scene { return true }
        return profile.routingCandidates(on: routingNetwork ?? .other).contains { $0.id == node.id }
    }

    var statusLabel: String {
        switch status {
        case .connecting: L10n.text("正在连接")
        case .connected: L10n.text("已连接")
        case .reasserting: L10n.text("正在重连")
        case .disconnecting: L10n.text("正在断开")
        default: L10n.text("未连接")
        }
    }

    func load() async {
        guard !busy else { return }
        do {
            let store = try ProfileStore.open()
            self.store = store
            profile = try store.read()
            #if os(iOS) && !targetEnvironment(simulator)
            let identifier = try tunnelIdentifier()
            manager = try await NETunnelProviderManager.loadAllFromPreferences().first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier
            }
            if observation == nil {
                observation = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange,
                                                                     object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                }
            }
            #endif
            ready = true
            refresh()
            if !connected { readArchivedTraffic() }
            #if os(macOS)
            await repairStaleSystemProxy()
            #endif
        } catch {
            message = error.localizedDescription
        }
    }

    #if os(macOS)
    /// 启动自检：清理历史版本或别的本地代理工具留下来的回环代理残留。
    /// 没有残留时直接返回，不提示、不提权；只有确实存在脏值才弹一次管理员授权。
    private func repairStaleSystemProxy() async {
        guard let repaired = try? await Task.detached(operation: { try SystemProxy.repairStale() }).value,
              repaired > 0 else { return }
        systemProxy = SystemProxy.current
        message = L10n.text("已清理 {0} 条失效的系统代理残留", repaired)
    }
    #endif

    func refresh() {
        let previousStatus = status
        let wasConnecting = status == .connecting || connected
        #if os(macOS)
        status = engine?.status ?? .invalid
        systemProxy = SystemProxy.current
        #else
        status = manager?.connection.status ?? .invalid
        #endif
        if !busy, let updated = try? store?.read(), updated != profile {
            probes = probes.filter { id, _ in
                guard let previous = profile.nodes.first(where: { $0.id == id }),
                      let current = updated.nodes.first(where: { $0.id == id }) else { return false }
                return previous.hasSameEndpoint(as: current)
            }
            profile = updated
        }
        let updatedNetwork = connected ? (try? store?.readRoutingNetwork()) : nil
        if updatedNetwork != routingNetwork { routingNetwork = updatedNetwork }
        let preferred = store?.activeNodeID() ?? profile.selectedID
        if !connected, profile.globalRoutingSettings.mode == .scene {
            activeID = profile.nodes.first { $0.id == preferred }?.id ?? profile.selected?.id
        } else {
            activeID = profile.selected(on: routingNetwork ?? .other, preferredID: preferred)?.id
        }
        if previousStatus != status, status == .disconnected || status == .invalid {
            readArchivedTraffic()
        }
        #if os(iOS)
        if wasConnecting, status == .disconnected {
            manager?.connection.fetchLastDisconnectError { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    guard self?.status == .disconnected else { return }
                    self?.message = error.localizedDescription
                }
            }
        }
        #endif
    }

    func addNode(link: String) throws {
        guard canEdit else { throw BywayError.message(L10n.text("请先断开隧道，再修改节点")) }
        let (updated, _) = try LANEdit.create(link: link, name: nil).applying(to: profile, activeID: activeID)
        try save(updated)
    }

    func removeNode(_ node: ProxyNode) {
        guard canEdit else { return }
        do {
            let (updated, _) = try LANEdit.delete(node.id).applying(to: profile, activeID: activeID)
            try save(updated)
            probes.removeValue(forKey: node.id)
        } catch {
            message = error.localizedDescription
        }
    }

    func setRelay(_ configuration: RelayConfiguration?) throws {
        guard canEdit else { throw BywayError.message(L10n.text("请先断开隧道，再更新 AI 控制")) }
        var updated = profile
        updated.relay = configuration
        try save(updated)
    }

    func saveImportedConfiguration(_ edit: LANEdit) throws {
        guard canEdit else { throw BywayError.message(L10n.text("请先断开 VPN，再修改分流配置")) }
        let (updated, _) = try edit.applying(to: profile, activeID: activeID)
        try save(updated)
    }

    func saveGlobalRouting(_ settings: GlobalRouting) async throws {
        try ensureAvailable()
        if connected {
            busy = true
            defer {
                busy = false
                refresh()
            }
            let reply: RoutingUpdateReply = try await send(RoutingUpdate(globalRouting: settings))
            guard reply.routing != nil else {
                throw BywayError.message(reply.error ?? L10n.text("无法保存路由设置"))
            }
        } else {
            let (updated, _) = try LANEdit.changeGlobalRouting(settings).applying(to: profile, activeID: activeID)
            try save(updated)
        }
    }

    func saveDNS(_ settings: DNSSettings) async throws {
        try ensureAvailable()
        if connected {
            busy = true
            defer {
                busy = false
                refresh()
            }
            let reply: DNSUpdateReply = try await send(DNSUpdate(dnsSettings: settings))
            guard reply.settings != nil else {
                throw BywayError.message(reply.error ?? L10n.text("无法保存 DNS 设置"))
            }
        } else {
            let (updated, _) = try LANEdit.changeDNS(settings).applying(to: profile, activeID: activeID)
            try save(updated)
        }
    }

    func toggleConnection() async {
        guard !busy else { return }
        #if os(macOS)
        if engine != nil || status == .connecting {
            await stopLocalEngine()
            return
        }
        guard canEdit, activeNode != nil || profile.privateNetwork?.enabled == true else { return }
        busy = true
        startingTunnel = true
        defer {
            startingTunnel = false
            busy = false
        }
        do {
            var updated = profile
            updated.selectedID = activeNode?.id
            try save(updated)
            guard let store else { throw BywayError.message(L10n.text("共享配置不可用")) }
            if let selected = updated.selectedID { try store.saveActiveNode(selected) }
            let engine: any MacProxyEngine
            switch takeover {
            case .tun:
                guard let tun = TunEngine() else { throw BywayError.message(L10n.text("无法准备全流量内核")) }
                engine = tun
            case .systemProxy, .listenOnly:
                engine = MacEngine()
            }
            try await engine.start(profile: updated, store: store)
            self.engine = engine
            status = engine.status
        } catch {
            message = error.localizedDescription
        }
        refresh()
        #else
        if connected || status == .connecting {
            manager?.connection.stopVPNTunnel()
            return
        }
        guard canEdit, activeNode != nil || profile.privateNetwork?.enabled == true else { return }
        #if targetEnvironment(simulator)
        message = L10n.text("请在 iPhone 真机上启动代理隧道。")
        #else
        busy = true
        startingTunnel = true
        defer {
            startingTunnel = false
            busy = false
        }
        do {
            var updated = profile
            updated.selectedID = activeNode?.id
            try save(updated)
            guard let store else { throw BywayError.message(L10n.text("共享配置不可用")) }
            if let selected = updated.selectedID { try store.saveActiveNode(selected) }
            let manager = try await prepareManager()
            try manager.connection.startVPNTunnel()
            refresh()
        } catch {
            message = error.localizedDescription
            refresh()
        }
        #endif
        #endif
    }

    #if os(macOS)
    private func stopLocalEngine() async {
        guard let engine else { return }
        busy = true
        defer { busy = false }
        // 先归还系统代理再停内核：反过来的话，中间这段时间系统代理指着已经关掉的
        // 混合端口，浏览器和 Electron 一类的程序会整段连不上（ERR_CONNECTION_CLOSED）。
        await releaseSystemProxyIfOurs()
        await engine.stop()
        self.engine = nil
        status = .invalid
        refresh()
    }

    /// 系统代理若还指着本机的混合端口，先还原成接管前的样子。
    private func releaseSystemProxyIfOurs() async {
        guard SystemProxy.current == .byway(port: MacSettings.mixedPort) else { return }
        do {
            try await Task.detached { try SystemProxy.clear() }.value
            systemProxy = SystemProxy.current
        } catch {
            message = error.localizedDescription
        }
    }

    /// 把系统代理指向本机混合端口。macOS 会为这次修改请求一次管理员授权。
    func applySystemProxy() async {
        let port = MacSettings.mixedPort
        do {
            // 授权对话框会阻塞调用线程，放到后台等待。
            try await Task.detached { try SystemProxy.apply(port: port) }.value
            systemProxy = SystemProxy.current
            message = L10n.text("系统代理已指向 127.0.0.1:{0}", port)
        } catch {
            message = error.localizedDescription
        }
    }

    /// 切换接管方式。已连接时先停旧引擎、再用新方式原地重连，
    /// 不用让用户先断开——切模式本身就是「换一种接管办法」，中间空档越短越好。
    func setTakeover(_ value: MacTakeover) async {
        guard !busy, takeover != value else { return }
        let wasConnected = engine != nil || status == .connecting
        takeover = value
        MacSettings.takeover = value
        guard wasConnected, let store else {
            refresh()
            return
        }
        // 两种进程内模式（系统代理 / 仅监听）共用同一个混合端口，不必重启内核。
        let needsRestart: Bool
        if engine is TunEngine {
            needsRestart = value != .tun
        } else if engine is MacEngine {
            needsRestart = value == .tun
        } else {
            needsRestart = true
        }
        guard needsRestart else {
            refresh()
            return
        }
        busy = true
        startingTunnel = true
        defer {
            startingTunnel = false
            busy = false
            refresh()
        }
        await releaseSystemProxyIfOurs()
        await retireCurrentEngine()
        do {
            var updated = profile
            updated.selectedID = activeNode?.id
            try save(updated)
            let next: any MacProxyEngine
            switch value {
            case .tun:
                guard let tun = TunEngine() else { throw BywayError.message(L10n.text("无法准备全流量内核")) }
                next = tun
            case .systemProxy, .listenOnly:
                next = MacEngine()
            }
            try await next.start(profile: updated, store: store)
            engine = next
            status = next.status
        } catch {
            message = error.localizedDescription
        }
    }

    /// 停掉当前引擎并复位状态。内核关闭（sing-box 的 `close()`）偶尔会长时间不返回，
    /// 不设上限的话切换会永远卡在 busy，界面停在「已连接」而实际已经没有任何接管。
    private func retireCurrentEngine() async {
        guard let previous = engine else { return }
        engine = nil
        status = .invalid
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await previous.stop() }
            group.addTask { try? await Task.sleep(for: .seconds(8)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// 全流量模式下显示虚拟网卡出口，其余模式显示混合端口。
    var localProxyAddress: String {
        switch takeover {
        case .tun: L10n.text("全流量（虚拟网卡）")
        case .systemProxy: "127.0.0.1:\(MacSettings.mixedPort)"
        case .listenOnly: "127.0.0.1:\(MacSettings.mixedPort)"
        }
    }

    func clearSystemProxy() async {
        do {
            try await Task.detached { try SystemProxy.clear() }.value
            systemProxy = SystemProxy.current
            message = L10n.text("系统代理已恢复")
        } catch {
            message = error.localizedDescription
        }
    }
    #endif

    func choose(_ node: ProxyNode) async {
        await runFromUI(.select, node: node)
    }

    func probe(_ node: ProxyNode) async {
        guard canTest else { return }
        await testNode(node)
    }

    func toggleBatchTest(only ids: Set<UUID>? = nil) {
        if let batchTask {
            stoppingBatch = true
            batchTask.cancel()
            return
        }
        let nodes = profile.nodes.filter { ids?.contains($0.id) ?? true }
        guard canTest, !nodes.isEmpty else { return }
        let usesTunnel = status == .connected
        batchProgress = (0, nodes.count)
        batchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                batchProgress = nil
                batchTask = nil
                stoppingBatch = false
            }
            for (index, node) in nodes.enumerated() {
                guard !Task.isCancelled, usesTunnel ? status == .connected : canHostLAN else { break }
                await testNode(node)
                batchProgress = (index + 1, nodes.count)
            }
        }
    }

    private func testNode(_ node: ProxyNode) async {
        let usesTunnel = status == .connected
        testingNodeID = node.id
        defer { testingNodeID = nil }
        do {
            _ = try await nodeCommand(.probe, id: node.id)
        } catch {
            if !Task.isCancelled, usesTunnel ? status == .connected : canHostLAN,
               profile.nodes.contains(where: { $0.id == node.id && $0.hasSameEndpoint(as: node) }) {
                probes[node.id] = .failed
            }
        }
    }

    func testBandwidth() async {
        guard canTestBandwidth, let node = activeNode else { return }
        measuringBandwidth = true
        bandwidth = nil
        bandwidthError = nil
        defer { measuringBandwidth = false }
        do {
            let reply: BandwidthReply = try await send(BandwidthRequest(bandwidthNodeID: node.id))
            if let result = reply.result {
                bandwidth = (node.name, result)
            } else {
                bandwidthError = reply.error ?? L10n.text("带宽测速失败，请重试")
            }
        } catch {
            bandwidthError = connected ? L10n.text("带宽测速失败，请重试") : L10n.text("VPN 已断开")
        }
    }

    func clearTrafficRates() {
        previousTraffic = nil
        trafficRates = nil
    }

    func refreshTraffic() async {
        guard connected else {
            if status != .disconnecting { readArchivedTraffic() }
            return
        }
        let sample: TrafficSnapshot? = try? await send(TrafficRequest.traffic)
        guard !Task.isCancelled, connected else { return }
        guard let sample else {
            clearTrafficRates()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let previousTraffic, previousTraffic.sample.connectionID == sample.connectionID {
            let elapsed = now - previousTraffic.uptime
            if elapsed >= 0.5 {
                trafficRates = sample.session.increase(since: previousTraffic.sample.session).perSecond(over: elapsed)
                self.previousTraffic = (sample, now)
            }
        } else {
            trafficRates = nil
            previousTraffic = (sample, now)
        }
        trafficSession = sample.session
        trafficTotal = sample.lifetime
    }

    private func readArchivedTraffic() {
        clearTrafficRates()
        trafficSession = nil
        trafficTotal = try? store?.readTrafficTotal()
    }

    func lanSnapshot() async throws -> LANSnapshot {
        refresh()
        guard canHostLAN else { throw LANFailure(409, L10n.text("VPN 正在接管局域网接口")) }
        return LANSnapshot(connected: false, activeID: activeID, profile: profile)
    }

    func lanEdit(_ edit: LANEdit) async throws -> LANEditReceipt {
        try ensureAvailable()
        guard canHostLAN else { throw LANFailure(409, L10n.text("VPN 正在接管局域网接口")) }
        let (updated, receipt) = try edit.applying(to: profile, activeID: activeID)
        try save(updated)
        if case .update(let id, let link, _) = edit, link != nil { probes.removeValue(forKey: id) }
        probes = probes.filter { id, _ in updated.nodes.contains { $0.id == id } }
        return receipt
    }

    func lanNodeCommand(_ operation: Operation, id: UUID) async throws -> CommandResult {
        guard canHostLAN else { throw LANFailure(409, L10n.text("VPN 正在接管局域网接口")) }
        return try await nodeCommand(operation, id: id)
    }

    func lanTrafficHistory() async throws -> TrafficHistory {
        try store?.readTrafficHistory() ?? TrafficHistory()
    }

    func lanCalls() async throws -> [LANCall] { try store?.readLANCalls() ?? [] }

    func lanPrivateStatus() async throws -> PrivateNetworkSettingsView {
        PrivateNetworkSettingsView(profile.privateNetwork)
    }

    func lanPrivateChange(_ change: PrivateNetworkChange) async throws -> PrivateNetworkReceipt {
        try ensureAvailable()
        guard canHostLAN else { throw LANFailure(409, L10n.text("VPN 正在接管局域网接口")) }
        let previous = profile.privateNetwork
        var next = profile
        next.privateNetwork = try change.applying(to: previous)
        try save(next)
        if case .leave = change, let previous { store?.removePrivateIdentity(previous.identity) }
        var completion: (@Sendable () -> Void)?
        if case .enable(true) = change {
            #if !targetEnvironment(simulator)
            completion = { [weak self] in
                Task { @MainActor in
                    guard let self, self.canEdit, self.profile.privateNetwork?.enabled == true else { return }
                    await self.toggleConnection()
                }
            }
            #endif
        }
        return PrivateNetworkReceipt(status: PrivateNetworkSettingsView(next.privateNetwork), afterReply: completion)
    }

    func privateNetworkLocalStatus(key: String? = nil) async throws -> PrivateNetworkSettingsView {
        guard connected else {
            if key != nil { throw LANFailure(409, L10n.text("请先启动 VPN")) }
            return PrivateNetworkSettingsView(profile.privateNetwork)
        }
        let command = PrivateNetworkLocalRequest(privateNetwork: key == nil ? .status : .key, key: key)
        let reply: MobileManagementReply = try await send(command)
        guard reply.status == 200 else {
            let error = try? JSONDecoder().decode([String: String].self, from: reply.payload)
            throw LANFailure(reply.status, error?["error"] ?? L10n.text("私网操作未完成"))
        }
        return try JSONDecoder().decode(PrivateNetworkSettingsView.self, from: reply.payload)
    }

    func refreshPrivateNetworkSummary() async {
        guard connected, let settings = profile.privateNetwork, settings.enabled else {
            privateNetworkSummary = nil
            lastPrivateNetworkSummary = .distantPast
            return
        }
        guard Date().timeIntervalSince(lastPrivateNetworkSummary) >= 3 else { return }
        lastPrivateNetworkSummary = .now
        let live = try? await privateNetworkLocalStatus()
        guard connected, profile.privateNetwork?.identity == settings.identity, profile.privateNetwork?.enabled == true else { return }
        privateNetworkSummary = live?.state
    }

    func lanVPNAction(enabled: Bool) async throws -> (@Sendable () -> Void)? {
        refresh()
        if !enabled && canHostLAN { return nil }
        guard canEdit, activeNode != nil || profile.privateNetwork?.enabled == true else {
            throw LANFailure(409, L10n.text("请在 Byway 中选择节点或启用私网"))
        }
        #if targetEnvironment(simulator)
        throw LANFailure(409, L10n.text("请在 iPhone 或 iPad 真机启动 VPN"))
        #else
        return { [weak self] in
            Task { @MainActor in
                guard let self, self.canEdit else { return }
                await self.toggleConnection()
            }
        }
        #endif
    }

    @discardableResult
    func manage(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        try ensureAvailable()
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let request = LANRequest(method: method, target: path, headers: ["content-type": "application/json"], body: data)
        let reply: MobileManagementReply
        if connected {
            reply = try await send(MobileManagementRequest(management: request))
        } else {
            let result = await LANAPI(backend: self).handle(request)
            result.afterReply?()
            reply = MobileManagementReply(status: result.status, payload: result.body)
        }
        refresh()
        guard (200..<300).contains(reply.status) else {
            let details = try? JSONDecoder().decode([String: String].self, from: reply.payload)
            throw LANFailure(reply.status, details?["error"] ?? L10n.text("操作失败"))
        }
        return reply.payload
    }

    func refreshTunnelLAN() async throws {
        #if os(iOS)
        guard connected else { return }
        let _: Bool = try await send(LANSettingsCommand.refresh)
        #endif
    }

    func nodeCommand(_ operation: Operation, id: UUID) async throws -> CommandResult {
        try ensureAvailable()
        guard let node = profile.nodes.first(where: { $0.id == id }) else { throw LANFailure.nodeNotFound }
        let command = Command(operation, nodeID: id)
        if canEdit, operation == .probe {
            let probe = try await probeWithoutTunnel(node)
            probes[id] = .succeeded(probe)
            return CommandResult(id: command.id,
                                 status: TunnelStatus(connected: false, selectedNodeID: activeID,
                                                      nodes: profile.nodes.map { NodeStatus(id: $0.id, name: $0.name) }),
                                 probe: probe, error: nil)
        }
        if canEdit, operation == .select {
            guard canSelectNode(node) else {
                throw BywayError.message(L10n.text("该节点不在当前节点组"))
            }
            guard let store else { throw BywayError.message(L10n.text("共享配置不可用")) }
            try store.saveActiveNode(id)
            refresh()
            return CommandResult(id: command.id,
                                 status: TunnelStatus(connected: false, selectedNodeID: activeID,
                                                      nodes: profile.nodes.map { NodeStatus(id: $0.id, name: $0.name) }),
                                 probe: nil, error: nil)
        }
        guard status == .connected else { throw LANFailure(409, L10n.text("请先连接 VPN")) }
        busy = true
        defer { busy = false; refresh() }
        let result: CommandResult = try await send(command)
        guard result.id == command.id else { throw BywayError.message(L10n.text("隧道返回了未知指令")) }
        if let message = result.error { throw BywayError.message(message) }
        if let probe = result.probe { probes[id] = .succeeded(probe) }
        return result
    }

    private func probeWithoutTunnel(_ node: ProxyNode) async throws -> Probe {
        let data = try JSONSerialization.data(withJSONObject: node.outboundConfiguration)
        let configuration = String(decoding: data, as: UTF8.self)
        busy = true
        defer { busy = false; refresh() }
        let probe = try await Task.detached {
            var error: NSError?
            guard let result = LibboxBywayProbeOutbound(configuration, &error) else {
                throw BywayError.message(L10n.text("节点未通过 HTTPS 连通性测试"))
            }
            return Probe(latencyMS: Int(result.latencyMS), exitIP: result.exitIP)
        }.value
        try Task.checkCancellation()
        guard canHostLAN else { throw LANFailure(409, L10n.text("VPN 状态已改变，请重新测试")) }
        return probe
    }

    private func runFromUI(_ operation: Operation, node: ProxyNode) async {
        do { _ = try await nodeCommand(operation, id: node.id) }
        catch { message = error.localizedDescription }
    }

    private func ensureAvailable() throws {
        try Task.checkCancellation()
        refresh()
        guard !busy, canEdit || status == .connected else {
            throw LANFailure(409, L10n.text("VPN 正在处理操作，请稍后重试"))
        }
    }

    private func save(_ updated: BywayProfile) throws {
        guard let store else { throw BywayError.message(L10n.text("共享配置不可用")) }
        try store.save(updated)
        profile = updated
        refresh()
    }

    private func send<Response: Decodable>(_ request: some Encodable) async throws -> Response {
        let data = try JSONEncoder().encode(request)
        #if os(macOS)
        guard let engine else { throw LANFailure(409, L10n.text("代理内核未运行")) }
        guard let reply = await engine.handle(data) else {
            throw BywayError.message(L10n.text("代理内核未返回结果"))
        }
        return try JSONDecoder().decode(Response.self, from: reply)
        #else
        guard let session = manager?.connection as? NETunnelProviderSession else {
            throw LANFailure(409, L10n.text("VPN 隧道不可用"))
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
            do {
                try session.sendProviderMessage(data) { response in
                    guard let response else {
                        continuation.resume(throwing: BywayError.message(L10n.text("隧道未返回结果")))
                        return
                    }
                    continuation.resume(with: Result { try JSONDecoder().decode(Response.self, from: response) })
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #endif
    }

    #if os(iOS)
    private func tunnelIdentifier() throws -> String {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "BywayTunnelIdentifier") as? String else {
            throw BywayError.message(L10n.text("应用缺少隧道标识"))
        }
        return identifier
    }

    private func prepareManager() async throws -> NETunnelProviderManager {
        let manager = self.manager ?? NETunnelProviderManager()
        if !manager.isEnabled || manager.protocolConfiguration == nil {
            let tunnel = NETunnelProviderProtocol()
            tunnel.providerBundleIdentifier = try tunnelIdentifier()
            tunnel.serverAddress = "Byway"
            manager.protocolConfiguration = tunnel
            manager.localizedDescription = "Byway"
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        self.manager = manager
        return manager
    }
    #endif
}
