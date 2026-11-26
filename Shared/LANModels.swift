import Foundation

struct LANSettings: Codable, Equatable, Sendable {
    let id: UUID
    let token: String

    init() {
        id = UUID()
        var random = SystemRandomNumberGenerator()
        token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &random)) }.joined()
    }
}

struct LANEndpoint: Codable, Equatable, Sendable {
    var address: String?
    var state: String
    var discovery: LANDiscovery?

    static let off = LANEndpoint(state: L10n.text("已关闭"))
    static let paused = LANEndpoint(state: L10n.text("已暂停"))
    static let handoff = LANEndpoint(state: L10n.text("正在连接局域网接口"))
}

struct LANPublishedEndpoint: Codable, Sendable {
    let settingsID: UUID
    let endpoint: LANEndpoint
}

enum LANSettingsCommand: String, Codable, Sendable {
    case refresh
}

struct LANSnapshot: Sendable {
    var connected: Bool
    var activeID: UUID?
    var profile: BywayProfile
    var routingNetwork: RoutingNetwork?
}

protocol LANBackend: Sendable {
    func lanSnapshot() async throws -> LANSnapshot
    func lanEdit(_ edit: LANEdit) async throws -> LANEditReceipt
    func lanNodeCommand(_ operation: Operation, id: UUID) async throws -> CommandResult
    func lanTrafficHistory() async throws -> TrafficHistory
    func lanDiagnostics() async throws -> MobileGatewayDiagnostics
    func lanCalls() async throws -> [LANCall]
    func lanCloseConnections(_ id: String?) async throws
    func lanVPNAction(enabled: Bool) async throws -> (@Sendable () -> Void)?
    func lanPrivateStatus() async throws -> PrivateNetworkSettingsView
    func lanPrivateChange(_ change: PrivateNetworkChange) async throws -> PrivateNetworkReceipt
    func lanPrivateProbe(address: String) async throws -> PrivateNetworkProbe
}

extension LANBackend {
    func lanTrafficHistory() async throws -> TrafficHistory { TrafficHistory() }
    func lanDiagnostics() async throws -> MobileGatewayDiagnostics { MobileGatewayDiagnostics() }
    func lanCalls() async throws -> [LANCall] { [] }
    func lanCloseConnections(_ id: String?) async throws { throw LANFailure(409, L10n.text("VPN 未连接")) }
    func lanVPNAction(enabled: Bool) async throws -> (@Sendable () -> Void)? {
        throw LANFailure(409, L10n.text("当前设备无法切换 VPN 状态"))
    }
    func lanPrivateStatus() async throws -> PrivateNetworkSettingsView {
        PrivateNetworkSettingsView(try await lanSnapshot().profile.privateNetwork)
    }
    func lanPrivateChange(_ change: PrivateNetworkChange) async throws -> PrivateNetworkReceipt {
        throw LANFailure(409, L10n.text("当前无法修改私网设置"))
    }
    func lanPrivateProbe(address: String) async throws -> PrivateNetworkProbe {
        throw LANFailure(409, L10n.text("私网未连接"))
    }
}

struct LANEditReceipt: Sendable {
    var node: ProxyNode?
    var routing: ProxyRouting
    var afterReply: (@Sendable () -> Void)?
    var importedConfiguration: ImportedConfigurationReport?
    var globalRouting: GlobalRouting?
    var dnsSettings: DNSSettings?
    var routingLibrary: RoutingLibrary?
    var subscriptionID: UUID?
    var nodeImport: NodeImportReport?
}

enum LANEdit: Sendable {
    case create(link: String, name: String?)
    case update(id: UUID, link: String?, name: String?)
    case delete(UUID)
    case changeRouting(LANRoutingPatch)
    case importConfiguration(text: String, acceptWarnings: Bool)
    case useImportedConfiguration(Bool)
    case changeGlobalRouting(GlobalRouting)
    case changeDNS(DNSSettings)
    case routingProfile(RoutingLibraryEdit)
    case importNodes(NodeImport, groupName: String?)
    case nodeCollection(NodeCollectionEdit)

    func applying(to current: BywayProfile, activeID: UUID?) throws -> (BywayProfile, LANEditReceipt) {
        var updated = current
        var editedNode: ProxyNode?
        var configurationReport: ImportedConfigurationReport?
        var subscriptionID: UUID?
        var nodeImport: NodeImportReport?
        switch self {
        case let .create(link, name):
            guard current.nodes.count < NodeSubscription.maxNodes else { throw BywayError.message(L10n.text("节点数已达上限")) }
            let node = try ProxyNode(link: link, name: name)
            try Self.checkDuplicate(node, in: current)
            updated.nodes.append(node)
            editedNode = node
        case let .update(id, link, name):
            guard let index = current.nodes.firstIndex(where: { $0.id == id }) else { throw LANFailure.nodeNotFound }
            let node = try current.nodes[index].updating(link: link, name: name)
            try Self.checkDuplicate(node, in: current)
            updated.nodes[index] = node
            editedNode = node
        case .delete(let id):
            guard current.nodes.contains(where: { $0.id == id }) else { throw LANFailure.nodeNotFound }
            updated.removeNodeFromCollections(id)
            if activeID == id || updated.selectedID == id { updated.selectedID = updated.nodes.first?.id }
        case .changeRouting(let patch):
            guard current.importedConfiguration?.enabled != true else {
                throw LANFailure(409, L10n.text("分流配置正在生效，请修改或停用导入的配置"))
            }
            updated.routing = try patch.applying(to: current.routingSettings).validated()
            if patch.dnsServer != nil { updated.dns?.mode = .configuration }
        case .importConfiguration(let text, let acceptWarnings):
            let imported = ImportedConfiguration(text: text, enabled: true)
            let report = try imported.report()
            guard acceptWarnings || report.warnings.isEmpty else {
                throw LANFailure(422, L10n.text("配置含有兼容提示，请先预览并确认"))
            }
            let library = current.savedRouting
            try updated.editRoutingLibrary(.save(id: library.activeID ?? library.configurations.first?.id,
                                                name: nil, text: text, acceptWarnings: acceptWarnings, activate: true))
            configurationReport = report
        case .useImportedConfiguration(let enabled):
            guard let imported = current.importedConfiguration,
                  let id = current.savedRouting.activeID ?? current.savedRouting.configurations.first?.id else {
                throw LANFailure(404, L10n.text("还没有导入分流配置"))
            }
            try updated.editRoutingLibrary(.activate(enabled ? id : nil))
            configurationReport = try ImportedConfiguration(text: imported.text, enabled: enabled).report()
        case .changeGlobalRouting(let routing):
            var normalized = routing
            for subscription in current.nodeSubscriptions {
                normalized.groups.removeAll { $0.id == subscription.id }
                if let group = current.globalRoutingSettings.groups.first(where: { $0.id == subscription.id }) {
                    normalized.groups.append(group)
                }
            }
            updated.globalRouting = try normalized.validated(nodes: updated.nodes)
        case .changeDNS(let settings):
            updated.dns = try settings.validated()
        case .routingProfile(let edit):
            try updated.editRoutingLibrary(edit)
        case let .importNodes(result, groupName):
            nodeImport = try updated.importNodes(result, groupName: groupName)
        case .nodeCollection(let edit):
            subscriptionID = try updated.editNodeCollection(edit)
        }
        return (updated, LANEditReceipt(node: editedNode, routing: updated.routingSettings,
                                        importedConfiguration: configurationReport,
                                        globalRouting: updated.globalRouting, dnsSettings: updated.dns,
                                        routingLibrary: updated.routingLibrary, subscriptionID: subscriptionID,
                                        nodeImport: nodeImport))
    }

    private static func checkDuplicate(_ node: ProxyNode, in profile: BywayProfile) throws {
        if profile.nodes.contains(where: { $0.id != node.id && $0.hasSameEndpoint(as: node) }) {
            throw BywayError.message(L10n.text("已添加相同的节点"))
        }
    }
}

struct LANRoutingPatch: Decodable, Sendable {
    let defaultRoute: ProxyRouting.DefaultRoute?
    let dnsServer: String?
    let bypassPrivateNetworks: Bool?
    let directDomains: [String]?

    func applying(to current: ProxyRouting) -> ProxyRouting {
        ProxyRouting(defaultRoute: defaultRoute ?? current.defaultRoute, dnsServer: dnsServer ?? current.dnsServer,
                     bypassPrivateNetworks: bypassPrivateNetworks ?? current.bypassPrivateNetworks,
                     directDomains: directDomains ?? current.directDomains)
    }
}
