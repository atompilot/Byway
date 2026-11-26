import Foundation

struct MobileAPI: Sendable {
    let backend: any LANBackend

    func handle(_ request: LANRequest) async throws -> LANResponse {
        guard let url = URLComponents(string: request.target) else { throw LANFailure(400, L10n.text("请求路径无效")) }
        let path = url.path
        let parts = path.split(separator: "/")
        switch (request.method, path) {
        case ("GET", "/v1/private-network"), ("GET", "/v1/private-network/config"):
            return LANResponse(200, try await backend.lanPrivateStatus())
        case ("GET", "/v1/private-network/peers"):
            return LANResponse(200, try await backend.lanPrivateStatus().runtime?.peers ?? [])
        case ("GET", "/v1/private-network/relays"):
            return LANResponse(200, try await backend.lanPrivateStatus())
        case ("PUT", "/v1/private-network/config"):
            let input = try request.decode(PrivateNetworkConfigInput.self,
                                           keys: ["provider", "controlURL", "relayHosts", "deviceName", "relayMode"])
            let configuration = PrivateNetworkInput(provider: input.provider, controlURL: input.controlURL ?? "",
                                                    relayHosts: input.relayHosts ?? [], deviceName: input.deviceName ?? "",
                                                    relayMode: input.relayMode ?? .strict)
            let result = try await backend.lanPrivateChange(.configure(configuration))
            return LANResponse(200, result.status)
        case ("POST", "/v1/private-network/join"):
            guard request.body.isEmpty else { throw LANFailure(400, L10n.text("请在设备上输入入网密钥，或通过浏览器授权")) }
            let result = try await backend.lanPrivateChange(.enable(true))
            return LANResponse(202, result.status, afterReply: result.afterReply)
        case ("PUT", "/v1/private-network/state"):
            let input = try request.decode(ProxyInput.self, keys: ["enabled"])
            let result = try await backend.lanPrivateChange(.enable(input.enabled))
            return LANResponse(200, result.status, afterReply: result.afterReply)
        case ("DELETE", "/v1/private-network/membership"):
            let result = try await backend.lanPrivateChange(.leave)
            return LANResponse(200, result.status, afterReply: result.afterReply)
        case ("POST", "/v1/private-network/probe"):
            let input = try request.decode(PrivateNetworkProbeInput.self, keys: ["address"])
            return LANResponse(200, try await backend.lanPrivateProbe(address: input.address))
        case ("GET", "/v1/guide"):
            return LANResponse(200, ["title": "Byway iPhone / iPad API", "guide": Self.guide])
        case ("GET", "/v1/statistics"):
            if let active = try await backend.lanDiagnostics().traffic { return LANResponse(200, active) }
            return LANResponse(200, ["lifetime": try await backend.lanTrafficHistory().lifetime])
        case ("GET", "/v1/statistics/history"):
            let range = url.queryItems?.first(where: { $0.name == "range" })?.value ?? "today"
            guard let range = TrafficRange(rawValue: range) else { throw LANFailure(422, L10n.text("不支持该统计范围")) }
            return LANResponse(200, range.report(try await backend.lanTrafficHistory()))
        case ("GET", "/v1/connections"):
            let diagnostics = try await backend.lanDiagnostics()
            return LANResponse(200, ConnectionReport(available: diagnostics.available, connections: diagnostics.connections))
        case ("DELETE", "/v1/connections"):
            try await backend.lanCloseConnections(nil)
            return LANResponse(200, ["closed": true])
        case ("GET", "/v1/diagnostics/engine"):
            let diagnostics = try await backend.lanDiagnostics()
            return LANResponse(200, EngineReport(available: diagnostics.available, logs: diagnostics.logs))
        case ("GET", "/v1/diagnostics/api-calls"):
            return LANResponse(200, try await backend.lanCalls())
        case ("PUT", "/v1/proxy"):
            let input = try request.decode(ProxyInput.self, keys: ["enabled"])
            let action = try await backend.lanVPNAction(enabled: input.enabled)
            return LANResponse(200, ["accepted": true, "enabled": input.enabled], afterReply: action)
        case ("GET", "/v1/config/routing"):
            return LANResponse(200, libraryState(try await backend.lanSnapshot().profile.savedRouting))
        case ("POST", "/v1/config/routing"):
            let input = try request.decode(RoutingInput.self, keys: ["name", "text", "acceptWarnings", "activate"])
            return try await editRouting(.save(id: nil, name: input.name, text: input.text,
                                               acceptWarnings: input.acceptWarnings == true, activate: input.activate == true))
        case ("PUT", "/v1/config/routing/active"):
            let input = try request.decode(ActiveRoutingInput.self, keys: ["id", "useDefault"])
            guard (input.id != nil) != (input.useDefault == true) else { throw LANFailure(400, L10n.text("请选择配置或默认分流")) }
            return try await editRouting(.activate(input.id))
        case ("POST", "/v1/config/routing/test-rule"):
            let input = try request.decode(RuleTestInput.self, keys: ["id", "host", "port"])
            if let port = input.port, !(1...65535).contains(port) { throw LANFailure(422, L10n.text("请输入有效的目标端口")) }
            let snapshot = try await backend.lanSnapshot()
            let node = snapshot.profile.nodes.first(where: { $0.id == snapshot.activeID })?.name
            let config = try input.id.map(snapshot.profile.savedRouting.configuration)
            let routing = snapshot.profile.routingSettings
            let match = try await Task.detached {
                if let config {
                    return try RoutingImportDocument(config.text).parsed.test(host: input.host, node: node, port: input.port)
                }
                return try ShadowrocketConfiguration.defaultTest(host: input.host, routing: routing, node: node)
            }.value
            return LANResponse(200, match)
        case ("GET", "/v1/groups"):
            let profile = try await backend.lanSnapshot().profile
            return LANResponse(200, profile.globalRoutingSettings.groups.map { group in
                GroupMetadata(id: group.id, name: group.name, nodeIDs: group.nodeIDs,
                              managedBySubscription: profile.nodeSubscriptions.contains { $0.id == group.id })
            })
        case ("GET", "/v1/subscriptions"):
            let profile = try await backend.lanSnapshot().profile
            return LANResponse(200, profile.nodeSubscriptions.map { SubscriptionMetadata($0, in: profile) })
        case ("POST", "/v1/subscriptions"):
            let input = try request.decode(SubscriptionInput.self, keys: ["link", "name"])
            guard let link = input.link else { throw LANFailure(400, L10n.text("请提供订阅链接")) }
            return try await subscribe(id: nil, previous: nil, link: link, name: input.name)
        case ("POST", "/v1/import"):
            let input = try request.decode(NodeImportInput.self, keys: ["link", "text", "parts", "name"])
            let parts = input.parts
            guard [input.text != nil, input.link != nil, parts != nil].filter({ $0 }).count == 1 else {
                throw LANFailure(400, L10n.text("提供链接、文件正文或分段码中的一项"))
            }
            var fragments = NodeShareParts()
            let code = try parts.map { parts -> String in
                guard !parts.isEmpty, parts.count <= 1500 else { throw LANFailure(400, L10n.text("分段码数量无效")) }
                var complete: String?
                guard parts.allSatisfy({ $0.lowercased().hasPrefix(NodeShare.partPrefix) }) else {
                    throw LANFailure(422, L10n.text("parts 只接受分段二维码"))
                }
                for part in parts { complete = try fragments.accept(part) ?? complete }
                guard let complete else { throw LANFailure(422, L10n.text("请提交完整的分段二维码")) }
                return complete
            }
            return try await importNodes(input.link ?? input.text ?? code ?? "", name: input.name)
        default:
            if parts.count == 3, parts[0] == "v1", parts[1] == "connections", request.method == "DELETE" {
                try await backend.lanCloseConnections(String(parts[2]))
                return LANResponse(200, ["closed": true])
            }
            if parts.count >= 3, parts[0] == "v1", parts[1] == "subscriptions",
               let id = UUID(uuidString: String(parts[2])) {
                return try await subscriptionRoute(request, id: id, action: parts.count == 4 ? String(parts[3]) : nil)
            }
            if parts.count == 4, parts[0] == "v1", parts[1] == "groups", parts[3] == "share",
               request.method == "GET", let id = UUID(uuidString: String(parts[2])) {
                let profile = try await backend.lanSnapshot().profile
                if let subscription = profile.nodeSubscriptions.first(where: { $0.id == id }) {
                    return share(NodeShare.subscription(subscription))
                }
                guard let group = profile.globalRoutingSettings.groups.first(where: { $0.id == id }) else {
                    throw LANFailure(404, L10n.text("节点组不存在"))
                }
                return try share(NodeShare.group(name: group.name, nodes: group.nodeIDs.compactMap { id in
                    profile.nodes.first { $0.id == id }
                }))
            }
            if (4...5).contains(parts.count), parts[0] == "v1", parts[1] == "config", parts[2] == "routing",
               let id = UUID(uuidString: String(parts[3])) {
                return try await routingRoute(request, id: id, action: parts.count == 5 ? String(parts[4]) : nil)
            }
            throw LANFailure(404, L10n.text("API 路径不存在"))
        }
    }

    func shareNode(_ id: UUID) async throws -> LANResponse {
        let profile = try await backend.lanSnapshot().profile
        guard let node = profile.nodes.first(where: { $0.id == id }) else { throw LANFailure.nodeNotFound }
        return try share(node.shareLink())
    }

    private func routingRoute(_ request: LANRequest, id: UUID, action: String?) async throws -> LANResponse {
        switch (request.method, action) {
        case ("GET", nil):
            let config = try await backend.lanSnapshot().profile.savedRouting.configuration(id)
            return LANResponse(200, config)
        case ("PATCH", nil):
            let input = try request.decode(RoutingInput.self, keys: ["name", "text", "acceptWarnings"])
            return try await editRouting(.save(id: id, name: input.name, text: input.text,
                                               acceptWarnings: input.acceptWarnings == true, activate: false))
        case ("DELETE", nil):
            return try await editRouting(.delete(id))
        case ("POST", "rules"):
            let input = try request.decode(RuleInput.self, keys: ["type", "value", "policy", "noResolve"])
            guard !input.type.contains(","), !input.value.contains(","), !input.policy.contains(",") else {
                throw LANFailure(422, L10n.text("分流字段无效"))
            }
            return try await editRouting(.insertRule(id, [input.type, input.value, input.policy].joined(separator: ",")
                                                     + (input.noResolve == true ? ",no-resolve" : "")))
        default:
            throw LANFailure(404, L10n.text("分流 API 路径不存在"))
        }
    }

    private func subscriptionRoute(_ request: LANRequest, id: UUID, action: String?) async throws -> LANResponse {
        let profile = try await backend.lanSnapshot().profile
        guard let subscription = profile.nodeSubscriptions.first(where: { $0.id == id }) else {
            throw LANFailure(404, L10n.text("订阅不存在"))
        }
        switch (request.method, action) {
        case ("GET", nil):
            return LANResponse(200, SubscriptionMetadata(subscription, in: profile))
        case ("PATCH", nil):
            let input = try request.decode(SubscriptionInput.self, keys: ["name", "link"])
            if let link = input.link {
                return try await subscribe(id: id, previous: subscription.address, link: link, name: input.name)
            }
            guard let name = input.name else { throw LANFailure(400, L10n.text("请提供订阅名称")) }
            _ = try await backend.lanEdit(.nodeCollection(.renameSubscription(id, name)))
            let updated = try await backend.lanSnapshot().profile
            guard let subscription = updated.nodeSubscriptions.first(where: { $0.id == id }) else {
                throw LANFailure(404, L10n.text("订阅不存在"))
            }
            return LANResponse(200, SubscriptionMetadata(subscription, in: updated))
        case ("DELETE", nil):
            let receipt = try await backend.lanEdit(.nodeCollection(.deleteSubscription(id)))
            return LANResponse(200, ["deleted": id], afterReply: receipt.afterReply)
        case ("POST", "refresh"):
            return try await subscribe(id: id, previous: subscription.address, link: subscription.address.absoluteString, name: nil)
        case ("GET", "share"):
            return share(NodeShare.subscription(subscription))
        default:
            throw LANFailure(404, L10n.text("订阅 API 路径不存在"))
        }
    }

    private func importNodes(_ input: String, name: String?) async throws -> LANResponse {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains(where: \.isNewline), ["sub://", "https://"].contains(where: { text.lowercased().hasPrefix($0) }) {
            return try await subscribe(id: nil, previous: nil, link: text, name: name)
        }
        let result: NodeImport
        let groupName: String?
        if text.lowercased().hasPrefix(NodeShare.groupPrefix) {
            let group = try NodeShare.readGroup(text)
            result = group.1
            groupName = name ?? group.0
        } else {
            result = try NodeImport(text)
            groupName = name
        }
        let receipt = try await backend.lanEdit(.importNodes(result, groupName: groupName))
        guard let report = receipt.nodeImport else { throw LANFailure(409, L10n.text("无法确认导入结果")) }
        return LANResponse(201, report)
    }

    private func subscribe(id: UUID?, previous: URL?, link: String, name: String?) async throws -> LANResponse {
        let source = try SubscriptionSource(link)
        let result: NodeImport
        do { result = try await source.fetch() }
        catch let error as BywayError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw LANFailure(503, L10n.text("订阅下载失败，现有订阅已保留")) }
        let receipt = try await backend.lanEdit(.nodeCollection(.subscription(id: id, previousAddress: previous,
                                                                              source: source, name: name, importResult: result)))
        let profile = try await backend.lanSnapshot().profile
        guard let subscription = profile.nodeSubscriptions.first(where: { $0.id == receipt.subscriptionID }) else {
            throw LANFailure(409, L10n.text("无法确认订阅已保存"))
        }
        return LANResponse(id == nil ? 201 : 200, SubscriptionMetadata(subscription, in: profile, skipped: result.skipped))
    }

    private func editRouting(_ edit: RoutingLibraryEdit) async throws -> LANResponse {
        let receipt = try await backend.lanEdit(.routingProfile(edit))
        return LANResponse(200, libraryState(receipt.routingLibrary ?? RoutingLibrary()))
    }

    private func share(_ link: String) -> LANResponse { LANResponse(200, ShareReport(link: link, parts: NodeShare.parts(link))) }

    private func libraryState(_ library: RoutingLibrary) -> RoutingState {
        RoutingState(activeID: library.activeID, configurations: library.configurations.map {
            RoutingMetadata(id: $0.id, name: $0.name)
        })
    }

    private struct ProxyInput: Decodable { let enabled: Bool }
    private struct PrivateNetworkProbeInput: Decodable { let address: String }
    private struct PrivateNetworkConfigInput: Decodable {
        let provider: PrivateNetworkInput.Provider
        let controlURL: String?
        let relayHosts: [String]?
        let deviceName: String?
        let relayMode: PrivateNetworkInput.RelayMode?
    }
    private struct ActiveRoutingInput: Decodable { let id: UUID?; let useDefault: Bool? }
    private struct RoutingInput: Decodable { let name: String?; let text: String?; let acceptWarnings: Bool?; let activate: Bool? }
    private struct RuleTestInput: Decodable { let id: UUID?; let host: String; let port: Int? }
    private struct RuleInput: Decodable { let type: String; let value: String; let policy: String; let noResolve: Bool? }
    private struct NodeImportInput: Decodable { let link: String?; let text: String?; let parts: [String]?; let name: String? }
    private struct SubscriptionInput: Decodable { let link: String?; let name: String? }
    private struct RoutingMetadata: Encodable { let id: UUID; let name: String }
    private struct RoutingState: Encodable { let activeID: UUID?; let configurations: [RoutingMetadata] }
    private struct ShareReport: Encodable { let link: String; let parts: [String] }
    private struct GroupMetadata: Encodable { let id: UUID; let name: String; let nodeIDs: [UUID]; let managedBySubscription: Bool }
    private struct ConnectionReport: Encodable { let available: Bool; let connections: [MobileConnection] }
    private struct EngineReport: Encodable { let available: Bool; let logs: [String] }

    private struct SubscriptionMetadata: Encodable {
        let id: UUID
        let name: String
        let host: String?
        let nodeIDs: [UUID]
        let usage: SubscriptionUsage?
        let remaining: Int64?
        let refreshedAt: Date
        let skipped: Int?

        init(_ subscription: NodeSubscription, in profile: BywayProfile, skipped: Int? = nil) {
            (id, name, host) = (subscription.id, subscription.name, subscription.address.host)
            nodeIDs = subscription.members(in: profile).map(\.id)
            usage = subscription.usage
            remaining = usage?.remaining
            refreshedAt = subscription.refreshedAt
            self.skipped = skipped
        }
    }

    static let guide = Bundle.main.url(forResource: "mobile-ai", withExtension: "md")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? """
    在相同 Wi-Fi 通过 Authorization: Bearer <令牌> 调用。节点用 /v1/nodes，订阅用 /v1/subscriptions。
    POST /v1/import 导入链接、正文或分段码。GET /v1/nodes/{id}/share 与 /v1/groups/{id}/share 返回分享内容。
    GET、POST /v1/config/routing 管理配置，PUT /v1/config/routing/active 切换配置。
    POST /v1/config/routing/test-rule 测试规则，POST /v1/config/routing/{id}/rules 添加规则。
    GET /v1/device 读取本机设备信息。GET /v1/status 的 deviceInfo 返回相同信息。
    PATCH /v1/device 使用 {"displayName":"设备名称"} 修改当前设备名称。按 id 区分设备。
    PUT /v1/proxy 请求启停 VPN，使用 {"enabled":true} 或 {"enabled":false}。通过 GET /v1/status 回读。
    GET /v1/private-network 回读私网。PUT /v1/private-network/config 保存配置，POST /v1/private-network/join 请求加入。
    Tailscale 账号可传 relayMode:tailscaleDefault 并留空 relayHosts。省略 relayMode 时严格匹配 relayHosts。
    PUT /v1/private-network/state 暂停或恢复，GET /v1/private-network/relays 查看实际下发的中继清单。
    GET /v1/statistics/history?range=today 读取流量历史。GET /v1/connections 查询连接，DELETE 同路径或带 ID 断开。
    GET /v1/diagnostics/engine 和 /v1/diagnostics/api-calls 读取脱敏日志。日期为 Swift JSONEncoder 的默认日期编码。
    """
}
