import Foundation
import Libbox
import NetworkExtension

actor TunnelRuntime: LANBackend {

    func handleMessage(_ messageData: Data) async -> Data? {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        if let request = try? decoder.decode(PrivateNetworkLocalRequest.self, from: messageData) {
            let response = privateLocalRequest(request)
            return try? encoder.encode(MobileManagementReply(status: response.status, payload: response.body))
        }
        if let request = try? decoder.decode(MobileManagementRequest.self, from: messageData) {
            let response = await LANAPI(backend: self).handle(request.management)
            let data = try? encoder.encode(MobileManagementReply(status: response.status, payload: response.body))
            if let completion = response.afterReply {
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    completion()
                }
            }
            return data
        }
        if (try? decoder.decode(LANSettingsCommand.self, from: messageData)) == .refresh {
            guard await refreshLAN() else { return nil }
            return try? encoder.encode(true)
        }
        if (try? decoder.decode(TrafficRequest.self, from: messageData)) == .traffic {
            guard let snapshot = trafficSnapshot() else { return nil }
            return try? encoder.encode(snapshot)
        }
        if let request = try? decoder.decode(BandwidthRequest.self, from: messageData) {
            return try? encoder.encode(await measureBandwidth(nodeID: request.bandwidthNodeID))
        }
        if let request = try? decoder.decode(RoutingUpdate.self, from: messageData) {
            return try? encoder.encode(await updateGlobalRouting(request.globalRouting))
        }
        if let request = try? decoder.decode(DNSUpdate.self, from: messageData) {
            return try? encoder.encode(await updateDNS(request.dnsSettings))
        }
        guard let command = try? decoder.decode(Command.self, from: messageData) else { return nil }
        return try? encoder.encode(await execute(command))
    }

    private var engine: LibboxCommandServer?
    private var platform: TunnelPlatform?
    private var profile = BywayProfile()
    private var store: ProfileStore?
    private var relayTask: Task<Void, Never>?
    private var trafficTask: Task<Void, Never>?
    private var traffic = TrafficAccumulator(previousLifetime: nil)
    private var trafficHistory: TrafficHistory?
    private var diagnostics: TunnelDiagnostics?
    private var speedTest: LibboxBywayNetworkTask?
    private var network: RoutingNetwork = .other
    private var networkAvailable = false
    private var networkMonitor: RoutingNetworkMonitor?
    private var networkTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var healthCheck: LibboxBywayNetworkTask?
    private var fallbackGeneration = UUID()
    private var consecutiveFailures = 0
    private weak var provider: NEPacketTunnelProvider?
    private var inbound: EngineInbound = .tun
    private var terminate: (@Sendable (Error?) -> Void)?
    private var lanServer: LANServer?
    private var stopping = false
    private var privateIdentityToRemove: UUID?

    func start(profile: BywayProfile, store: ProfileStore, provider: NEPacketTunnelProvider?,
               inbound: EngineInbound = .tun, terminate: (@Sendable (Error?) -> Void)? = nil) async throws {
        guard engine == nil, !stopping else { throw BywayError.message(L10n.text("隧道已启动")) }
        let monitor = RoutingNetworkMonitor()
        let network = monitor.initial ?? .other
        let config = try profile.engineConfiguration(network: network, privateStateRoot: store.directory,
                                                     inbound: inbound)
        let folder = FileManager.default.temporaryDirectory.appending(path: "byway-engine", directoryHint: .isDirectory)
        #if os(iOS)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        #else
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #endif
        let setup = LibboxSetupOptions()
        setup.basePath = folder.path
        setup.workingPath = folder.path
        setup.tempPath = folder.path
        setup.appVersion = "1"
        setup.appMarketingVersion = "0.1.0"
        setup.logMaxLines = 50
        setup.oomKillerEnabled = true
        var setupError: NSError?
        LibboxSetup(setup, &setupError)
        if let setupError { throw setupError }

        let platform = TunnelPlatform(provider: provider)
        var engineError: NSError?
        guard let engine = LibboxNewCommandServer(platform, platform, &engineError) else {
            throw engineError ?? BywayError.message(L10n.text("无法创建代理内核")) as NSError
        }
        do {
            try engine.startOrReloadService(config, options: LibboxOverrideOptions())
        } catch {
            engine.close()
            throw BywayError.message(L10n.text("代理内核启动失败：{0}", error.localizedDescription))
        }
        self.engine = engine
        self.platform = platform
        self.profile = profile
        self.store = store
        self.provider = provider
        self.inbound = inbound
        self.terminate = terminate
        if (try? engine.start()) != nil { diagnostics = TunnelDiagnostics() }
        self.network = network
        networkAvailable = monitor.initial != nil
        networkMonitor = monitor
        if let id = selectedID() { try? store.saveActiveNode(id) }
        try? store.saveRoutingNetwork(network)
        networkTask = Task { [weak self, updates = monitor.updates] in
            for await update in updates { await self?.networkChanged(update) }
        }
        refreshFallbackTask()
        trafficHistory = try? store.readTrafficHistory()
        traffic = TrafficAccumulator(previousLifetime: trafficHistory?.lifetime)
        trafficTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
                await self?.persistTraffic()
            }
        }
        try? store.saveLANEndpoint(nil)
        #if os(macOS)
        // macOS 版由主 App 的局域网控制独占端口，内核不再另起监听。
        #else
        let server = await LANServer()
        guard self.engine === engine else { return }
        lanServer = server
        _ = await refreshLAN()
        guard self.engine === engine else { return }
        #endif
        if let relay = profile.relay {
            relayTask = Task { [weak self] in
                await self?.runRelay(relay)
            }
        }
    }

    func stop() async {
        guard let engine, !stopping else { return }
        stopping = true
        defer { stopping = false }
        trafficTask?.cancel()
        trafficTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        networkTask?.cancel()
        networkTask = nil
        networkMonitor?.stop()
        networkMonitor = nil
        resetFallback()
        try? store?.saveRoutingNetwork(nil)
        speedTest?.cancel()
        persistTraffic()
        diagnostics?.stop()
        diagnostics = nil
        self.engine = nil
        let server = lanServer
        lanServer = nil
        provider = nil
        await server?.endSession()
        let task = relayTask
        relayTask = nil
        task?.cancel()
        await task?.value
        try? engine.closeService()
        engine.close()
        if let identity = privateIdentityToRemove {
            store?.removePrivateIdentity(identity)
            privateIdentityToRemove = nil
        }
        platform = nil
        if let relay = profile.relay {
            // The broker expires stale heartbeats if the extension is stopped without a clean shutdown.
            let client = RelayClient(relay)
            defer { client.session.invalidateAndCancel() }
            _ = try? await client.exchange(DeviceExchange(status: status(), completion: nil), stopping: true)
        }
    }

    private func selectedID() -> UUID? {
        guard let engine else { return nil }
        var error: NSError?
        let value = engine.bywaySelected(&error)
        guard error == nil else { return nil }
        return UUID(uuidString: value)
    }

    private func status() -> TunnelStatus {
        let selected = profile.nodes.isEmpty ? nil : selectedID()
        return TunnelStatus(connected: engine != nil && !stopping, selectedNodeID: selected,
                            nodes: profile.nodes.map { NodeStatus(id: $0.id, name: $0.name) })
    }

    func trafficSnapshot() -> TrafficSnapshot? {
        guard let sample = try? engine?.bywayTraffic() else { return nil }
        traffic.observe(TrafficBytes(upload: sample.uploadBytes, download: sample.downloadBytes))
        return traffic.snapshot
    }

    private func persistTraffic() {
        guard let store, var history = trafficHistory, let usage = trafficSnapshot()?.lifetime else { return }
        let time = Date()
        let key = Int64(floor(time.timeIntervalSince1970 / 900) * 900)
        guard usage != history.lifetime || history.samples[key] == nil else { return }
        history.observe(lifetime: usage, at: time)
        do {
            try store.saveTrafficHistory(history)
            trafficHistory = history
        } catch {
            // Later checkpoints can save the full amount again.
        }
    }

    func measureBandwidth(nodeID: UUID) async -> BandwidthReply {
        guard let engine, !stopping, let node = profile.nodes.first(where: { $0.id == nodeID }) else {
            return BandwidthReply(error: L10n.text("隧道或节点不可用"))
        }
        guard speedTest == nil else { return BandwidthReply(error: L10n.text("正在测速")) }
        defer { speedTest = nil }
        return await withCheckedContinuation { continuation in
            let handler = BandwidthHandler(continuation)
            do {
                speedTest = try engine.bywayStartSpeedTest(node.tag, handler: handler)
            } catch {
                continuation.resume(returning: BandwidthReply(error: L10n.text("无法开始带宽测速")))
            }
        }
    }

    func refreshLAN() async -> Bool {
        guard let store, let server = lanServer, engine != nil, !stopping else { return false }
        return await MainActor.run { [weak self] in
            do {
                guard let settings = try store.readLANSettings() else {
                    server.stop()
                    try? store.saveLANEndpoint(nil)
                    return true
                }
                server.start(settings, store: store) { endpoint in
                    guard endpoint != .off else { return }
                    try? store.saveLANEndpoint(LANPublishedEndpoint(settingsID: settings.id, endpoint: endpoint))
                } handle: { [weak self] request in
                    guard let self else { return LANResponse(LANFailure(503, L10n.text("VPN 已停止"))) }
                    return await LANAPI(backend: self).handle(request)
                }
                return true
            } catch {
                server.stop()
                return false
            }
        }
    }

    func lanSnapshot() async throws -> LANSnapshot {
        guard engine != nil, !stopping else { throw LANFailure(409, L10n.text("VPN 已停止")) }
        let state = status()
        return LANSnapshot(connected: state.connected, activeID: state.selectedNodeID, profile: profile,
                           routingNetwork: network)
    }

    func lanTrafficHistory() async throws -> TrafficHistory {
        persistTraffic()
        return try trafficHistory ?? store?.readTrafficHistory() ?? TrafficHistory()
    }

    private func privateSnapshot(includeAuth: Bool = false) -> PrivateNetworkSettingsView {
        guard profile.privateNetwork?.enabled == true, let engine, !stopping else {
            return PrivateNetworkSettingsView(profile.privateNetwork)
        }
        var error: NSError?
        let data = Data(engine.bywayPrivateStatus(&error).utf8)
        var runtime = error == nil ? try? JSONDecoder().decode(PrivateNetworkRuntime.self, from: data) : nil
        if !includeAuth { runtime?.authURL = nil }
        return PrivateNetworkSettingsView(profile.privateNetwork, runtime: runtime)
    }

    func lanPrivateStatus() async throws -> PrivateNetworkSettingsView { privateSnapshot() }

    func lanPrivateChange(_ change: PrivateNetworkChange) async throws -> PrivateNetworkReceipt {
        guard let store, engine != nil, !stopping else { throw LANFailure(409, L10n.text("VPN 正在停止")) }
        var next = profile
        let previous = profile.privateNetwork
        next.privateNetwork = try change.applying(to: profile.privateNetwork)
        if let runtime = privateSnapshot().runtime, var settings = next.privateNetwork {
            settings.lastAddresses = Array(Set(settings.lastAddresses + runtime.peers.flatMap(\.addresses)).sorted().prefix(4096))
            settings.lastDNSSuffix = runtime.dnsSuffix ?? settings.lastDNSSuffix
            next.privateNetwork = settings
        }
        if case .leave = change, next.nodes.isEmpty {
            try store.save(next)
            profile = next
            privateIdentityToRemove = previous?.identity
            return PrivateNetworkReceipt(status: privateSnapshot(), afterReply: { [weak self] in
                Task { await self?.requestStop() }
            })
        }
        try applyProfile(next, store: store)
        if case .leave = change, let previous {
            store.removePrivateIdentity(previous.identity)
        }
        return PrivateNetworkReceipt(status: privateSnapshot())
    }

    func lanPrivateProbe(address: String) async throws -> PrivateNetworkProbe {
        let data = try privateAction("probe", value: address)
        return try JSONDecoder().decode(PrivateNetworkProbe.self, from: data)
    }

    func privateLocalRequest(_ request: PrivateNetworkLocalRequest) -> LANResponse {
        do {
            if request.privateNetwork == .key {
                guard let key = request.key, !key.isEmpty, key.utf8.count <= 4096 else {
                    throw LANFailure(422, L10n.text("请填写有效的入网密钥"))
                }
                _ = try privateAction("join", value: key)
            }
            return LANResponse(200, privateSnapshot(includeAuth: true))
        } catch let error as LANFailure {
            return LANResponse(error)
        } catch {
            return LANResponse(LANFailure(409, L10n.text("私网操作未完成，请检查连接状态")))
        }
    }

    private func privateAction(_ action: String, value: String) throws -> Data {
        guard let engine, profile.privateNetwork?.enabled == true, !stopping else {
            throw LANFailure(409, L10n.text("私网未连接"))
        }
        var error: NSError?
        let result = engine.bywayPrivateAction(action, value: value, error: &error)
        guard error == nil else {
            throw LANFailure(409, action == "probe" ? L10n.text("设备未响应或私网尚未就绪") : L10n.text("入网授权未完成，请检查密钥"))
        }
        return Data(result.utf8)
    }

    func lanCalls() async throws -> [LANCall] { try store?.readLANCalls() ?? [] }

    func lanDiagnostics() async throws -> MobileGatewayDiagnostics {
        var result = diagnostics?.snapshot() ?? MobileGatewayDiagnostics()
        result.traffic = trafficSnapshot()
        let names = Dictionary(uniqueKeysWithValues: profile.nodes.map { ($0.tag, $0.name) })
        result.connections = result.connections.map { connection in
            MobileConnection(id: connection.id, source: connection.source, destination: connection.destination,
                             network: connection.network, rule: connection.rule,
                             outbound: names[connection.outbound] ?? connection.outbound, traffic: connection.traffic)
        }
        return result
    }

    func lanCloseConnections(_ id: String?) async throws {
        guard let diagnostics else { throw LANFailure(409, L10n.text("连接诊断不可用")) }
        try diagnostics.close(id)
    }

    func lanVPNAction(enabled: Bool) async throws -> (@Sendable () -> Void)? {
        guard engine != nil, !stopping else { throw LANFailure(409, L10n.text("VPN 正在停止")) }
        guard !enabled else { return nil }
        let stop: @Sendable () -> Void = { [weak self] in Task { await self?.requestStop() } }
        Task {
            try? await Task.sleep(for: .seconds(2))
            stop()
        }
        return stop
    }

    private func requestStop() {
        guard !stopping, engine != nil else { return }
        requestTermination(nil)
    }

    private func requestTermination(_ error: Error?) {
        if let provider {
            provider.cancelTunnelWithError(error)
            return
        }
        terminate?(error)
    }

    func lanEdit(_ edit: LANEdit) async throws -> LANEditReceipt {
        try Task.checkCancellation()
        guard let store, engine != nil, !stopping else {
            throw LANFailure(409, L10n.text("VPN 正在停止"))
        }
        let (updated, initial) = try edit.applying(to: profile, activeID: selectedID())
        var receipt = initial
        if updated.nodes.isEmpty, updated.privateNetwork == nil {
            try store.save(updated)
            profile = updated

            // Flush the acknowledgement first so the client can confirm the deletion.
            receipt.afterReply = { [weak self] in
                Task { await self?.disconnectEmptyTunnel() }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.disconnectEmptyTunnel()
            }
        } else {
            try applyProfile(updated, store: store)
        }
        return receipt
    }

    func lanNodeCommand(_ operation: Operation, id: UUID) async throws -> CommandResult {
        try Task.checkCancellation()
        guard engine != nil, !stopping else { throw LANFailure(409, L10n.text("VPN 已停止")) }
        guard profile.nodes.contains(where: { $0.id == id }) else { throw LANFailure.nodeNotFound }
        let result = execute(Command(operation, nodeID: id))
        if let message = result.error { throw BywayError.message(message) }
        return result
    }

    private func disconnectEmptyTunnel() {
        guard profile.nodes.isEmpty else { return }
        requestStop()
    }

    func updateGlobalRouting(_ settings: GlobalRouting) async -> RoutingUpdateReply {
        do {
            let receipt = try await lanEdit(.changeGlobalRouting(settings))
            return RoutingUpdateReply(routing: receipt.globalRouting)
        } catch {
            return RoutingUpdateReply(error: error.localizedDescription)
        }
    }

    func updateDNS(_ settings: DNSSettings) async -> DNSUpdateReply {
        do {
            let receipt = try await lanEdit(.changeDNS(settings))
            return DNSUpdateReply(settings: receipt.dnsSettings)
        } catch {
            return DNSUpdateReply(error: error.localizedDescription)
        }
    }

    private func networkChanged(_ observed: RoutingNetwork?) {
        guard engine != nil, !stopping else { return }
        networkAvailable = observed != nil
        guard let observed else {
            resetFallback()
            return
        }
        guard observed != network, let store else { return }
        if profile.globalRoutingSettings.mode == .scene {
            do { try applyProfile(profile, store: store, network: observed) }
            catch {
                // An active scene defines which traffic may use the proxy on this network.
                requestTermination(error)
                return
            }
        } else {
            network = observed
            resetFallback()
            try? store.saveRoutingNetwork(observed)
        }
    }

    private func applyProfile(_ requested: BywayProfile, store: ProfileStore,
                              network newNetwork: RoutingNetwork? = nil) throws {
        guard let engine else {
            throw BywayError.message(L10n.text("当前隧道无法更新配置"))
        }
        let active = selectedID()
        let destinationNetwork = newNetwork ?? network
        var next = requested
        let selected = next.selected(on: destinationNetwork, preferredID: active)?.id
        guard selected != nil || next.nodes.isEmpty && next.privateNetwork != nil else {
            throw BywayError.message(L10n.text("当前节点组没有可用成员"))
        }
        next.selectedID = selected
        var previous = profile
        previous.selectedID = active
        let before = try previous.engineConfiguration(network: network, privateStateRoot: store.directory,
                                                      inbound: inbound)
        let after = try next.engineConfiguration(network: destinationNetwork, privateStateRoot: store.directory,
                                                 inbound: inbound)
        let reload = before != after
        if reload {
            var validationError: NSError?
            guard LibboxCheckConfig(after, &validationError) else {
                throw BywayError.message(L10n.text("代理内核拒绝了配置"))
            }
        }
        let selectionChanged = selected != active
        do {
            if reload { try reloadEngine(engine, configuration: after) }
            guard selectedID() == selected else { throw BywayError.message(L10n.text("无法确认配置已生效")) }
            if selectionChanged, let selected { try store.saveActiveNode(selected) }
            if newNetwork == nil { try store.save(next) }
            if profile.globalRoutingSettings != next.globalRoutingSettings || destinationNetwork != network {
                resetFallback()
            }
            profile = next
            refreshFallbackTask()
            if destinationNetwork != network {
                network = destinationNetwork
                try? store.saveRoutingNetwork(network)
            }
        } catch {
            if selectionChanged, let active { try? store.saveActiveNode(active) }
            if reload {
                do {
                    try reloadEngine(engine, configuration: before)
                    guard selectedID() == active else { throw BywayError.message(L10n.text("无法确认原配置已恢复")) }
                } catch {
                    let recoveryError = BywayError.message(L10n.text("配置更新和恢复失败，隧道已停止"))
                    requestTermination(recoveryError)
                    throw recoveryError
                }
            }
            throw BywayError.message(L10n.text("配置未保存，已保留原配置"))
        }
    }

    private func reloadEngine(_ engine: LibboxCommandServer, configuration: String) throws {
        resetFallback()
        speedTest?.cancel()
        persistTraffic()
        traffic.resetEngineCounters()
        try engine.startOrReloadService(configuration, options: LibboxOverrideOptions())
    }

    private func resetFallback() {
        fallbackGeneration = UUID()
        consecutiveFailures = 0
        healthCheck?.cancel()
        healthCheck = nil
    }

    private func refreshFallbackTask() {
        if !profile.globalRoutingSettings.fallback {
            fallbackTask?.cancel()
            fallbackTask = nil
        } else if fallbackTask == nil {
            fallbackTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) }
                    catch { return }
                    await self?.checkFallback()
                }
            }
        }
    }

    private func checkFallback() async {
        let decision = profile.globalRoutingSettings.decision(on: network)
        let candidates = profile.routingCandidates(on: network)
        guard !Task.isCancelled, networkAvailable, !stopping, profile.globalRoutingSettings.fallback,
              decision.mode != .direct, candidates.count > 1, let active = selectedID(), let engine else { return }
        let generation = fallbackGeneration
        let currentOK = await checkHealth(active.uuidString.lowercased(), engine: engine, generation: generation)
        guard fallbackGeneration == generation, selectedID() == active, !Task.isCancelled else { return }
        if currentOK {
            consecutiveFailures = 0
            return
        }
        consecutiveFailures = min(consecutiveFailures + 1, 2)
        guard consecutiveFailures == 2 else { return }
        for candidate in candidates where candidate.id != active {
            let healthy = await checkHealth(candidate.tag, engine: engine, generation: generation)
            guard fallbackGeneration == generation, selectedID() == active, !Task.isCancelled else { return }
            if healthy, (try? selectNode(candidate, using: engine)) != nil { return }
        }
    }

    private func checkHealth(_ tag: String, engine: LibboxCommandServer, generation: UUID) async -> Bool {
        defer { if fallbackGeneration == generation { healthCheck = nil } }
        return await withCheckedContinuation { continuation in
            do {
                healthCheck = try engine.bywayStartHealthCheck(tag, handler: HealthCheckHandler(continuation))
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    private func selectNode(_ node: ProxyNode, using engine: LibboxCommandServer) throws {
        let previous = selectedID()
        try engine.bywaySelect(node.tag)
        do {
            guard selectedID() == node.id else { throw BywayError.message(L10n.text("无法确认当前出口")) }
            try store?.saveActiveNode(node.id)
            resetFallback()
        } catch {
            if let previous { try? engine.bywaySelect(previous.uuidString.lowercased()) }
            throw BywayError.message(L10n.text("切换未能完成，请检查当前出口"))
        }
    }

    func execute(_ command: Command) -> CommandResult {
        do {
            if let expiry = command.expiresAt, Date().timeIntervalSince1970 >= expiry {
                throw BywayError.message(L10n.text("指令已过期"))
            }
            var probe: Probe?
            if command.operation != .status {
                guard let node = profile.nodes.first(where: { $0.id == command.nodeID }),
                      let engine else {
                    throw BywayError.message(L10n.text("隧道或节点不可用"))
                }
                if command.operation == .probe {
                    probe = try runProbe(engine: engine, node: node)
                } else {
                    guard profile.routingCandidates(on: network).contains(where: { $0.id == node.id }) else {
                        throw BywayError.message(L10n.text("该节点不在当前节点组"))
                    }
                    // Verify the target from the phone before moving existing connections.
                    probe = try runProbe(engine: engine, node: node)
                    try selectNode(node, using: engine)
                }
            }
            return CommandResult(id: command.id, status: status(), probe: probe, error: nil)
        } catch {
            let message = (error as? BywayError)?.localizedDescription ?? L10n.text("代理操作失败")
            return CommandResult(id: command.id, status: status(), probe: nil, error: message)
        }
    }

    private func runProbe(engine: LibboxCommandServer, node: ProxyNode) throws -> Probe {
        do {
            let result = try engine.bywayProbe(node.tag)
            return Probe(latencyMS: Int(result.latencyMS), exitIP: result.exitIP)
        } catch {
            throw BywayError.message(L10n.text("节点未通过 HTTPS 连通性测试"))
        }
    }

    private func runRelay(_ configuration: RelayConfiguration) async {
        let client = RelayClient(configuration)
        defer { client.session.invalidateAndCancel() }
        var completion: CommandResult?
        var retrySeconds = 1
        while !Task.isCancelled {
            do {
                let snapshot = DeviceExchange(status: status(), completion: completion)
                let reply = try await client.exchange(snapshot)
                try Task.checkCancellation()
                retrySeconds = 1
                if reply.acknowledged == completion?.id { completion = nil }
                if let command = reply.command {
                    if command.id != completion?.id { completion = execute(command) }
                } else {
                    try await Task.sleep(for: .milliseconds(300))
                }
            } catch {
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(retrySeconds))
                retrySeconds = min(retrySeconds * 2, 30)
            }
        }
    }
}

private final class HealthCheckHandler: NSObject, LibboxBywayHealthHandlerProtocol {
    let continuation: CheckedContinuation<Bool, Never>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func onHealthResult(_ healthy: Bool) {
        continuation.resume(returning: healthy)
    }
}

private final class BandwidthHandler: NSObject, LibboxBywaySpeedTestHandlerProtocol {
    let continuation: CheckedContinuation<BandwidthReply, Never>

    init(_ continuation: CheckedContinuation<BandwidthReply, Never>) {
        self.continuation = continuation
    }

    func onComplete(_ result: LibboxBywaySpeedResult?, message: String?) {
        let measurement = result.map {
            BandwidthResult(downloadBitsPerSecond: $0.downloadBitsPerSecond,
                            uploadBitsPerSecond: $0.uploadBitsPerSecond)
        }
        continuation.resume(returning: BandwidthReply(result: measurement, error: message))
    }
}

private struct RelayClient {
    let configuration: RelayConfiguration
    let session: URLSession

    init(_ configuration: RelayConfiguration) {
        self.configuration = configuration
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 24
        settings.timeoutIntervalForResource = 25
        session = URLSession(configuration: settings, delegate: RelayRedirectPolicy(), delegateQueue: nil)
    }

    func exchange(_ exchange: DeviceExchange, stopping: Bool = false) async throws -> RelayReply {
        var request = URLRequest(url: configuration.exchangeURL)
        request.httpMethod = "POST"
        if stopping { request.timeoutInterval = 2 }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + configuration.deviceKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(exchange)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(RelayReply.self, from: data)
    }
}

private final class RelayRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
