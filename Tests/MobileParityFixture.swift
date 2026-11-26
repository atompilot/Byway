import Foundation

@main
struct MobileParityFixture {
    static func main() throws {
        try migrateRouting()
        #if os(macOS)
        try macGeoIPRules()
        #endif
        try capturePrivateNetworkRoutes()
        try migratePrivateNetworkRelayMode()
        try refreshSubscription()
        try reportImportedNodes()
        try shareNodes()
        try recordTrafficHistory()
        print("Mobile routing and private network migration, subscription reconciliation, node import, share codes and traffic history passed.")
    }

    #if os(macOS)
    private static func macGeoIPRules() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let configuration = try ShadowrocketConfiguration("[Rule]\nGEOIP,CN,DIRECT\nFINAL,PROXY")
        let ruleSet = directory.appending(path: "geoip-cn.srs")
        precondition(store.geoIPRuleSetURL == ProfileStore.bundledGeoIPRuleSetURL)
        do {
            _ = try configuration.test(host: "114.114.114.114", node: nil, geoIPRuleSetURL: nil)
            preconditionFailure("A GEOIP rule must report missing data")
        } catch let error as LANFailure {
            precondition(error.status == 503)
        }
        try Data(repeating: 0, count: 34_259).write(to: ruleSet)
        precondition(store.geoIPRuleSetURL == ProfileStore.bundledGeoIPRuleSetURL)
        if let upstreamFile = ProcessInfo.processInfo.environment["BYWAY_TEST_GEOIP_RULESET"] {
            try Data(contentsOf: URL(fileURLWithPath: upstreamFile)).write(to: ruleSet, options: .atomic)
            precondition(store.geoIPRuleSetURL == ruleSet)
            let match = try configuration.test(host: "114.114.114.114", node: nil, geoIPRuleSetURL: store.geoIPRuleSetURL)
            precondition(match.policy == "DIRECT" && match.rule.uppercased() == "GEOIP,CN,DIRECT")
        }
    }
    #endif

    private static func migrateRouting() throws {
        let first = "[Rule]\nDOMAIN-SUFFIX,example.org,DIRECT\nFINAL,PROXY"
        let second = "[Rule]\nIP-CIDR,192.0.2.0/24,REJECT,no-resolve\nFINAL,DIRECT"
        let encoded = try JSONSerialization.data(withJSONObject: [
            "nodes": [], "importedConfiguration": ["text": first, "enabled": true]
        ])
        var profile = try JSONDecoder().decode(BywayProfile.self, from: encoded)
        let importedID = try require(profile.savedRouting.activeID)
        precondition(profile.savedRouting.activeID == importedID)

        try profile.editRoutingLibrary(.save(id: nil, name: "备份", text: second, acceptWarnings: false, activate: false))
        let backup = try require(profile.savedRouting.configurations.last)
        precondition(profile.savedRouting.activeID == importedID && profile.importedConfiguration?.text == first)
        try profile.editRoutingLibrary(.activate(backup.id))
        try profile.editRoutingLibrary(.insertRule(backup.id, "DOMAIN,example.org,PROXY"))
        let rule = try ShadowrocketConfiguration(try require(profile.importedConfiguration).text)
        let domain = try rule.test(host: "example.org", node: "Fixture")
        precondition(domain.policy == "PROXY" && domain.lineNumber == 2)
        let rejected = try rule.test(host: "192.0.2.213", node: nil)
        precondition(rejected.policy == "REJECT")
        let unresolved = try rule.test(host: "no-resolve.example", node: nil, resolving: { _ in
            preconditionFailure("no-resolve must not perform DNS")
        })
        precondition(unresolved.policy == "DIRECT")
        try profile.editRoutingLibrary(.delete(backup.id))
        precondition(profile.savedRouting.activeID == nil && profile.importedConfiguration?.enabled == false)
        let recovered = try JSONDecoder().decode(BywayProfile.self, from: JSONEncoder().encode(profile))
        precondition(recovered.savedRouting.configurations.first?.id == importedID)
    }

    private static func capturePrivateNetworkRoutes() throws {
        let exclusions = ["100.64.0.0/10", "100.80.0.0/16", "fd7a:115c:a1e0::/48", "fc00::/7", "192.168.0.0/16"]
        let config = "[General]\ntun-excluded-routes = \(exclusions.joined(separator: ", "))\n[Rule]\nFINAL,DIRECT"
        let old = try JSONSerialization.data(withJSONObject: [
            "nodes": [], "importedConfiguration": ["text": config, "enabled": true]
        ])
        var profile = try JSONDecoder().decode(BywayProfile.self, from: old)
        let input = PrivateNetworkInput(provider: .headscale, controlURL: "https://head.example.org",
                                        relayHosts: ["derp.example.org"], deviceName: "test")
        profile.privateNetwork = PrivateNetworkSettings(identity: UUID(), input: input, enabled: true)
        let stateRoot = URL(fileURLWithPath: "/tmp/byway-test")

        func tunnel(_ profile: BywayProfile) throws -> [String: Any] {
            let json = try profile.engineConfiguration(privateStateRoot: stateRoot)
            let engine = try require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return try require((engine["inbounds"] as? [[String: Any]])?.first)
        }

        let enabled = try tunnel(profile)
        precondition(enabled["route_address"] as? [String] == ["100.64.0.0/10", "fd7a:115c:a1e0::/48"])
        precondition(enabled["route_exclude_address"] as? [String] == ["fc00::/7", "192.168.0.0/16"])

        profile.privateNetwork?.enabled = false
        let paused = try tunnel(profile)
        precondition(paused["route_address"] == nil)
        precondition(paused["route_exclude_address"] as? [String] == exclusions)
    }

    private static func migratePrivateNetworkRelayMode() throws {
        let identity = UUID()
        let old = Data("""
        {"identity":"\(identity)","enabled":true,"lastAddresses":["100.80.0.1"],"lastDNSSuffix":"example.ts.net","input":{
          "provider":"tailscale","controlURL":"https://controlplane.tailscale.com",
          "relayHosts":["derp.example.org"],"deviceName":"old-device"
        }}
        """.utf8)
        let strict = try JSONDecoder().decode(PrivateNetworkSettings.self, from: old)
        precondition(strict.input.relayMode == .strict && strict.identity == identity && strict.enabled)
        let follow = try strict.update(PrivateNetworkInput(provider: .tailscale, controlURL: "",
                                                          relayHosts: [], deviceName: "old-device",
                                                          relayMode: .tailscaleDefault))
        let restored = try JSONDecoder().decode(PrivateNetworkSettings.self, from: JSONEncoder().encode(follow))
        precondition(restored == follow && follow.identity == identity && follow.enabled)
        precondition(follow.lastAddresses == ["100.80.0.1"] && follow.lastDNSSuffix == "example.ts.net")

        var profile = BywayProfile()
        profile.nodes = try NodeImport("socks5://192.0.2.1:1080#fixture").nodes
        for settings in [strict, follow] {
            profile.privateNetwork = settings
            let json = try profile.engineConfiguration(privateStateRoot: URL(fileURLWithPath: "/tmp/byway-test"))
            let engine = try require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let endpoint = try require((engine["endpoints"] as? [[String: Any]])?.first)
            let route = try require(engine["route"] as? [String: Any])
            let routes = try require(route["rules"] as? [[String: Any]])
            precondition(endpoint["control_url"] as? String == "https://controlplane.tailscale.com")
            precondition(route["final"] as? String == "byway")
            precondition(routes.contains { $0["preferred_by"] as? String == PrivateNetworkSettings.tag })
            if settings.input.relayMode == .strict {
                precondition(endpoint["byway_relays"] as? [String] == ["derp.example.org"])
                precondition(endpoint["byway_follow_control_relays"] == nil)
            } else {
                precondition(endpoint["byway_relays"] == nil)
                precondition(endpoint["byway_follow_control_relays"] as? Bool == true)
            }
        }
    }

    private static func refreshSubscription() throws {
        let source = try SubscriptionSource("https://example.org/feed#Fixture")
        let initial = try NodeImport("socks5://192.0.2.1:1080#one\nsocks5://192.0.2.2:1080#two")
        var profile = BywayProfile()
        let id = try require(profile.editNodeCollection(.subscription(id: nil, previousAddress: nil,
                                                                         source: source, name: nil, importResult: initial)))
        let original = try require(profile.nodes.first)
        profile.nodes[0] = try original.updating(link: "socks5://192.0.2.9:1080", name: "用户修改")
        profile.removeNodeFromCollections(profile.nodes[1].id)

        let update = try NodeImport("socks5://192.0.2.3:1080#one\nsocks5://192.0.2.2:1080#two\nsocks5://192.0.2.4:1080#three",
                                    usage: SubscriptionUsage("upload=10; download=25; total=100; expire=1800000000"))
        _ = try profile.editNodeCollection(.subscription(id: id, previousAddress: source.address,
                                                          source: source, name: nil, importResult: update))
        precondition(profile.nodes.count == 2 && profile.nodes[0].id == original.id)
        precondition(profile.nodes[0].host == "192.0.2.9" && profile.nodes[0].name == "用户修改")
        precondition(profile.nodeSubscriptions.first?.usage?.remaining == 65)
        precondition(profile.globalRoutingSettings.groups.first?.id == id)
        _ = try profile.editNodeCollection(.deleteSubscription(id))
        precondition(profile.nodes.isEmpty && profile.globalRoutingSettings.groups.isEmpty)
    }

    private static func reportImportedNodes() throws {
        let first = "socks5://192.0.2.1:1080#one"
        let unrelated = try ProxyNode(link: "socks5://192.0.2.3:1080#unrelated")
        let existing = try ProxyNode(link: first)
        var profile = BywayProfile()
        profile.nodes = [existing, unrelated]
        let result = try NodeImport("\(first)\nsocks5://192.0.2.2:1080#two\nunsupported")

        let (updated, receipt) = try LANEdit.importNodes(result, groupName: "Imported").applying(to: profile, activeID: nil)
        let report = try require(receipt.nodeImport)
        let newNode = try require(updated.nodes.last)
        precondition(report.parsed == 2 && report.added == 1 && report.skipped == 1)
        precondition(report.nodeIDs == [existing.id, newNode.id] && newNode.name == "two")
        precondition(updated.globalRoutingSettings.groups.last?.nodeIDs == report.nodeIDs)

        let (repeated, retry) = try LANEdit.importNodes(result, groupName: nil).applying(to: updated, activeID: nil)
        precondition(retry.nodeImport?.added == 0 && retry.nodeImport?.nodeIDs == report.nodeIDs)
        precondition(repeated.nodes == updated.nodes)
    }

    private static func shareNodes() throws {
        let examples = [
            "socks5://user:secret@192.0.2.5:1080#SOCKS",
            "ss://aes-256-gcm:secret@192.0.2.6:1080#Shadowsocks",
            "vless://4B9DD025-D9A0-4F51-B17F-A83BC26BCB7E@192.0.2.7:443?type=ws&path=%2Fws&security=tls#VLESS",
            "vless://4B9DD025-D9A0-4F51-B17F-A83BC26BCB7E@192.0.2.8:443?security=reality&fp=safari&pbk=fixture#REALITY"
        ]
        var nodes = try examples.map { try ProxyNode(link: $0) }
        let vmess = ["add": "example.org", "port": "443", "id": UUID().uuidString, "net": "ws",
                     "ps": "VMess", "security": "auto", "tls": "tls", "path": "/ws"]
        let encoded = try JSONEncoder().encode(vmess).base64EncodedString()
        nodes.append(try ProxyNode(link: "vmess://" + encoded))
        for node in nodes {
            let reconstructed = try ProxyNode(link: node.shareLink())
            precondition(reconstructed.name == node.name && reconstructed.hasSameEndpoint(as: node))
        }
        for index in 1...50 {
            nodes.append(try ProxyNode(link: "vless://\(UUID())@example.org:443?security=tls#\(index)"))
        }
        let code = try NodeShare.group(name: "跨端组", nodes: nodes)
        let parts = NodeShare.parts(code)
        precondition(parts.count > 1)
        var reader = NodeShareParts()
        var restored: String?
        for part in parts.reversed() { restored = try reader.accept(part) }
        let (name, group) = try NodeShare.readGroup(try require(restored))
        precondition(name == "跨端组" && group.nodes.count == nodes.count)
        precondition(zip(group.nodes, nodes).allSatisfy { $0.hasSameEndpoint(as: $1) })
    }

    private static func recordTrafficHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ProfileStore(directory: folder)
        let legacy = TrafficBytes(upload: 30, download: 70)
        try JSONEncoder().encode(legacy).write(to: folder.appending(path: "traffic.json"))
        var history = try store.readTrafficHistory()
        let time = try require(ISO8601DateFormatter().date(from: "2026-11-24T16:00:00Z"))
        history.observe(lifetime: TrafficBytes(upload: 33, download: 77), at: time)
        try store.saveTrafficHistory(history)
        let total = try store.readTrafficTotal()
        precondition(total.total == 110)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try require(TimeZone(identifier: "America/Los_Angeles"))
        let report = try TrafficRange.today.report(store.readTrafficHistory(), now: time, calendar: calendar)
        precondition(report.total == TrafficBytes(upload: 3, download: 7))
        precondition(report.bins.contains { $0.state == .missing } && report.bins.contains { $0.state == .future })
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw BywayError.message("Fixture value missing") }
        return value
    }
}
