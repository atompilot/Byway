import Foundation

struct SubscriptionUsage: Codable, Equatable, Sendable {
    let upload: Int64?
    let download: Int64?
    let total: Int64?
    let expires: Int64?

    init?(_ header: String?) {
        guard let header else { return nil }
        var values: [String: Int64] = [:]
        for field in header.split(separator: ";") {
            let pair = field.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let value = Int64(pair[1].trimmingCharacters(in: .whitespaces)), value >= 0 else { continue }
            values[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = value
        }
        (upload, download, total, expires) = (values["upload"], values["download"], values["total"], values["expire"])
        guard upload != nil || download != nil || total != nil || expires != nil else { return nil }
    }

    var remaining: Int64? {
        guard let upload, let download, let total else { return nil }
        return max(0, max(0, total - upload) - download)
    }
}

struct SubscriptionSource: Sendable {
    let address: URL
    let suggestedName: String

    init(_ link: String) throws {
        var text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        var name: String?
        if text.lowercased().hasPrefix("sub://") {
            let fields = text.dropFirst(6).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard let payload = fields.first, let data = NodeImport.decodeBase64(String(payload)),
                  let url = String(data: data, encoding: .utf8) else {
                throw BywayError.message("订阅链接无法解码")
            }
            text = url
            if fields.count == 2 { name = fields[1].removingPercentEncoding }
        }
        guard text.utf8.count <= 8192, var url = URLComponents(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw BywayError.message("订阅地址需要使用 HTTPS")
        }
        name = name ?? url.fragment
        url.fragment = nil
        guard let address = url.url else { throw BywayError.message("订阅地址无效") }
        self.address = address
        suggestedName = String((name.map { $0.isEmpty ? host : $0 } ?? host).prefix(50))
    }

    func fetch() async throws -> NodeImport {
        var request = URLRequest(url: address, timeoutInterval: 20)
        request.setValue("Shadowrocket/2.2.93", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 25
        let session = URLSession(configuration: configuration, delegate: HTTPSSubscriptionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.expectedContentLength <= NodeImport.maxBytes else {
            throw BywayError.message("订阅服务器响应异常或内容过大")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < NodeImport.maxBytes else { throw BywayError.message("订阅内容超过 4 MB") }
            data.append(byte)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw BywayError.message("订阅内容需要使用 UTF-8 编码")
        }
        return try NodeImport(text, usage: SubscriptionUsage(response.value(forHTTPHeaderField: "subscription-userinfo")))
    }
}

private final class HTTPSSubscriptionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}

struct NodeSubscription: Codable, Equatable, Identifiable, Sendable {
    static let maxNodes = 512
    let id: UUID
    var name: String
    var address: URL
    var originals: [ProxyNode]
    var usage: SubscriptionUsage?
    var refreshedAt: Date

    func members(in profile: BywayProfile) -> [ProxyNode] {
        let ids = Set(originals.map(\.id))
        return profile.nodes.filter { ids.contains($0.id) }
    }
}

struct NodeImport: Sendable {
    static let maxBytes = 4 * 1024 * 1024
    var nodes: [ProxyNode]
    var skipped: Int
    var usage: SubscriptionUsage?

    init(_ source: String, usage: SubscriptionUsage? = nil) throws {
        guard source.utf8.count <= Self.maxBytes else { throw BywayError.message("导入内容超过 4 MB") }
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: ["\u{feff}"])
        if text.hasPrefix("[") {
            let entries = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] ?? []
            guard entries.count <= 2048 else { throw BywayError.message("导入的条目过多") }
            nodes = entries.compactMap { try? Self.shadowrocket($0) }
            skipped = entries.count - nodes.count
        } else {
            let decoded = text.contains("://") ? text :
                (Self.decodeBase64(text).flatMap { String(data: $0, encoding: .utf8) } ?? text)
            let links = decoded.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard links.count <= 2048 else { throw BywayError.message("导入的条目过多") }
            nodes = links.compactMap { try? ProxyNode(link: $0) }
            skipped = links.count - nodes.count
        }
        nodes = nodes.reduce(into: []) { unique, node in
            if !unique.contains(where: { $0.hasSameEndpoint(as: node) && $0.name == node.name }) { unique.append(node) }
        }
        guard !nodes.isEmpty, nodes.count <= NodeSubscription.maxNodes else {
            throw BywayError.message("需要 1 至 512 个可用节点")
        }
        self.usage = usage
    }

    static func decodeBase64(_ value: String) -> Data? {
        let clean = value.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: clean + String(repeating: "=", count: (4 - clean.utf8.count % 4) % 4))
    }

    private static func shadowrocket(_ entry: [String: Any]) throws -> ProxyNode {
        func text(_ key: String) -> String { entry[key].map { String(describing: $0) } ?? "" }
        guard text("type").uppercased() == "VLESS", let port = Int(text("port")), (1...65535).contains(port),
              ["", "none", "tcp", "raw"].contains(text("obfs").lowercased()),
              ["", "none"].contains(text("plugin").lowercased()),
              ["", "none"].contains(text("proto").lowercased()) else {
            throw BywayError.message("此节点导出格式不受支持")
        }
        var url = URLComponents()
        url.scheme = "vless"
        let host = text("host").trimmingCharacters(in: ["[", "]"])
        url.host = host.contains(":") ? "[\(host)]" : host
        url.port = port
        url.user = text("password")
        url.fragment = text("title")
        let key = text("publicKey")
        let security = !key.isEmpty ? "reality" : (["1", "true"].contains(text("tls").lowercased()) ? "tls" : "none")
        let fingerprint = text("tlsProfile").lowercased()
        url.queryItems = [("security", security), ("sni", text("peer")), ("pbk", key), ("sid", text("shortId")),
                          ("flow", text("flow")), ("alpn", text("alpn")), ("fp", fingerprint.hasPrefix("safari") ? "safari" : fingerprint)]
            .filter { !$0.1.isEmpty }.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let link = url.string else { throw BywayError.message("无法读取节点") }
        return try ProxyNode(link: link)
    }
}

struct NodeImportReport: Encodable, Sendable {
    let parsed: Int
    let skipped: Int
    let added: Int
    let nodeIDs: [UUID]
}

enum NodeCollectionEdit: Sendable {
    case subscription(id: UUID?, previousAddress: URL?, source: SubscriptionSource, name: String?, importResult: NodeImport)
    case renameSubscription(UUID, String)
    case deleteSubscription(UUID)
}

extension BywayProfile {
    var nodeSubscriptions: [NodeSubscription] { subscriptions ?? [] }

    mutating func importNodes(_ result: NodeImport, groupName: String?) throws -> NodeImportReport {
        let previousCount = nodes.count
        var members: [UUID] = []
        for node in result.nodes {
            if let existing = nodes.first(where: { $0.hasSameEndpoint(as: node) && $0.name == node.name }) {
                members.append(existing.id)
            } else {
                nodes.append(node)
                members.append(node.id)
            }
        }
        try checkNodeLimit()
        if let groupName {
            var routing = globalRoutingSettings
            routing.groups.append(RoutingGroup(name: groupName, nodeIDs: members))
            globalRouting = try routing.validated(nodes: nodes)
        }
        return NodeImportReport(parsed: members.count, skipped: result.skipped,
                                added: nodes.count - previousCount, nodeIDs: members)
    }

    mutating func editNodeCollection(_ edit: NodeCollectionEdit) throws -> UUID? {
        switch edit {
        case let .subscription(id, previousAddress, source, name, result):
            return try updateSubscription(id: id, previousAddress: previousAddress, source: source, name: name, result: result)
        case let .renameSubscription(id, name):
            guard var subscription = nodeSubscriptions.first(where: { $0.id == id }) else {
                throw LANFailure(404, "订阅不存在")
            }
            subscription.name = name
            try storeSubscription(subscription)
            return id
        case let .deleteSubscription(id):
            guard let subscription = nodeSubscriptions.first(where: { $0.id == id }) else {
                throw LANFailure(404, "订阅不存在")
            }
            for node in subscription.members(in: self) { removeNodeFromCollections(node.id) }
            subscriptions?.removeAll { $0.id == id }
            globalRouting?.removeGroup(id)
            return id
        }
    }

    mutating func removeNodeFromCollections(_ id: UUID) {
        nodes.removeAll { $0.id == id }
        globalRouting?.removeNode(id)
        if selectedID == id { selectedID = nodes.first?.id }
    }

    private mutating func updateSubscription(id: UUID?, previousAddress: URL?, source: SubscriptionSource,
                                             name: String?, result: NodeImport) throws -> UUID {
        let existing = nodeSubscriptions.first { id == nil ? $0.address == source.address : $0.id == id }
        if id != nil, existing?.address != previousAddress || existing == nil {
            throw LANFailure(409, "订阅已变更，请重新读取")
        }
        if let existing, existing.address != source.address {
            for old in existing.members(in: self) { removeNodeFromCollections(old.id) }
        }
        let originals = existing?.address == source.address ? existing?.originals ?? [] : []
        let local = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var unclaimed = originals
        var refreshed: [ProxyNode] = []
        for incoming in result.nodes {
            let exact = unclaimed.firstIndex { $0.name == incoming.name && $0.hasSameEndpoint(as: incoming) }
                ?? unclaimed.firstIndex { $0.hasSameEndpoint(as: incoming) }
            let nameMatches = unclaimed.indices.filter { unclaimed[$0].name == incoming.name && unclaimed[$0].protocolName == incoming.protocolName }
            let index = exact ?? (nameMatches.count == 1 ? nameMatches.first : nil)
            if let index {
                let original = unclaimed.remove(at: index)
                let revised = incoming.withID(original.id)
                refreshed.append(revised)
                guard let saved = local[original.id], let slot = nodes.firstIndex(where: { $0.id == original.id }) else { continue }
                let endpoint = saved.hasSameEndpoint(as: original) ? revised : saved
                nodes[slot] = try endpoint.updating(link: nil, name: saved.name == original.name ? revised.name : saved.name)
            } else {
                nodes.append(incoming)
                refreshed.append(incoming)
            }
        }
        for removed in unclaimed { removeNodeFromCollections(removed.id) }
        try checkNodeLimit()
        let subscription = NodeSubscription(id: existing?.id ?? UUID(), name: name ?? existing?.name ?? source.suggestedName,
                                            address: source.address, originals: refreshed, usage: result.usage, refreshedAt: Date())
        try storeSubscription(subscription)
        return subscription.id
    }

    private mutating func storeSubscription(_ subscription: NodeSubscription) throws {
        var subscription = subscription
        subscription.name = subscription.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...50).contains(subscription.name.count),
              subscription.name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !nodeSubscriptions.contains(where: { $0.id != subscription.id && $0.address == subscription.address }) else {
            throw LANFailure(422, "订阅地址重复或名称无效")
        }
        var subscriptions = nodeSubscriptions.filter { $0.id != subscription.id }
        subscriptions.append(subscription)
        guard subscriptions.count <= 32 else { throw LANFailure(422, "最多可保存 32 个订阅") }
        var routing = globalRoutingSettings
        let members = subscription.members(in: self).map(\.id)
        if members.isEmpty {
            routing.removeGroup(subscription.id)
        } else {
            let group = RoutingGroup(id: subscription.id, name: subscription.name, nodeIDs: members)
            if let index = routing.groups.firstIndex(where: { $0.id == subscription.id }) {
                routing.groups[index] = group
            } else {
                routing.groups.append(group)
            }
        }
        globalRouting = try routing.validated(nodes: nodes)
        self.subscriptions = subscriptions
    }

    private func checkNodeLimit() throws {
        guard nodes.count <= NodeSubscription.maxNodes else { throw LANFailure(422, "最多可保存 512 个节点") }
    }
}
