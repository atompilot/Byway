import Foundation

enum RoutingMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case rules, proxy, direct, scene

    var id: Self { self }
    var title: String {
        switch self {
        case .rules: "按配置"
        case .proxy: "全局代理"
        case .direct: "全局直连"
        case .scene: "按场景"
        }
    }
}

enum RoutingNetwork: String, CaseIterable, Codable, Sendable, Identifiable {
    case wifi, cellular, wired, other

    var id: Self { self }
    var title: String {
        switch self {
        case .wifi: "Wi‑Fi"
        case .cellular: "蜂窝网络"
        case .wired: "有线网络"
        case .other: "其他网络"
        }
    }
}

struct RoutingGroup: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var nodeIDs: [UUID] = []
}

struct RoutingScene: Codable, Equatable, Sendable {
    var network: RoutingNetwork
    var mode: RoutingMode = .rules
    var groupID: UUID?
}

struct RoutingDecision: Codable, Equatable, Sendable {
    let mode: RoutingMode
    let groupID: UUID?
}

struct GlobalRouting: Codable, Equatable, Sendable {
    var mode: RoutingMode = .rules
    var fallback = false
    var groupID: UUID?
    var groups: [RoutingGroup] = []
    var scenes: [RoutingScene] = []

    func decision(on network: RoutingNetwork) -> RoutingDecision {
        if mode == .scene,
           let scene = scenes.first(where: { $0.network == network })
            ?? scenes.first(where: { $0.network == .other }) {
            return RoutingDecision(mode: scene.mode, groupID: scene.groupID)
        }
        return RoutingDecision(mode: mode == .scene ? .rules : mode, groupID: groupID)
    }

    func candidates(in decision: RoutingDecision, nodes: [ProxyNode]) -> [ProxyNode] {
        guard let id = decision.groupID, let group = groups.first(where: { $0.id == id }) else { return nodes }
        let known = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        return group.nodeIDs.compactMap { known[$0] }
    }

    func validated(nodes: [ProxyNode]) throws -> Self {
        var value = self
        let known = Set(nodes.map(\.id))
        let groupIDs = Set(groups.map(\.id))
        guard groups.count <= 32, groups.count == groupIDs.count,
              Set(scenes.map(\.network)).count == scenes.count,
              scenes.allSatisfy({ $0.mode != .scene && ($0.groupID.map(groupIDs.contains) ?? true) }),
              groupID.map(groupIDs.contains) ?? true else {
            throw BywayError.message("节点组或场景配置无效")
        }
        for index in value.groups.indices {
            value.groups[index].name = value.groups[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            let group = value.groups[index]
            guard (1...50).contains(group.name.count),
                  !group.nodeIDs.isEmpty, Set(group.nodeIDs).count == group.nodeIDs.count,
                  group.nodeIDs.allSatisfy(known.contains) else {
                throw BywayError.message("每个节点组需要名称和至少一个已添加的节点")
            }
        }
        guard Set(value.groups.map { $0.name.lowercased() }).count == value.groups.count else {
            throw BywayError.message("节点组名称重复")
        }
        return value
    }

    mutating func removeNode(_ id: UUID) {
        for index in groups.indices { groups[index].nodeIDs.removeAll { $0 == id } }
        for group in groups where group.nodeIDs.isEmpty { removeGroup(group.id) }
    }

    mutating func removeGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        if groupID == id { groupID = nil }
        for index in scenes.indices where scenes[index].groupID == id { scenes[index].groupID = nil }
    }
}

struct RoutingUpdate: Codable, Sendable {
    let globalRouting: GlobalRouting
}

struct RoutingUpdateReply: Codable, Sendable {
    var routing: GlobalRouting?
    var error: String?
}
