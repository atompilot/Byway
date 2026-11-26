import Foundation
import Network

enum BywayError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

struct ProxyNode: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
    private let outbound: Data

    var tag: String { id.uuidString.lowercased() }

    var outboundConfiguration: [String: Any] {
        get throws {
            guard var options = try JSONSerialization.jsonObject(with: outbound) as? [String: Any] else {
                throw BywayError.message(L10n.text("节点配置损坏"))
            }
            options["tag"] = tag
            return options
        }
    }

    init(link: String, id: UUID = UUID(), name: String? = nil) throws {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("vmess://") {
            self = try Self.vmess(text, id: id, name: name)
            return
        }
        guard text.utf8.count <= 4096,
              let url = Self.nodeURL(text),
              let type = url.scheme?.lowercased(),
              let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty,
              let port = url.port, (1...65535).contains(port) else {
            throw BywayError.message(L10n.text("节点链接需要包含主机和有效端口"))
        }
        self.id = id
        self.name = try name.map(Self.validName) ?? url.fragment?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty.map { String($0.prefix(80)) } ?? host
        self.host = host
        self.port = port
        var options: [String: Any] = ["type": type, "server": host, "server_port": port]
        let fields = Dictionary(url.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                                uniquingKeysWith: { first, _ in first })
        switch type {
        case "ss":
            try Self.configureShadowsocks(url, fields: fields, options: &options)
        case "socks", "socks5":
            guard fields.isEmpty else { throw BywayError.message(L10n.text("SOCKS5 链接包含未知选项")) }
            options["type"] = "socks"
            options["version"] = "5"
            options["username"] = url.user
            options["password"] = url.password
        case "vless":
            guard let user = url.user, let uuid = UUID(uuidString: user), url.password == nil else {
                throw BywayError.message(L10n.text("VLESS 节点需要有效的 UUID"))
            }
            let transport = fields["type"] ?? "tcp"
            guard ["tcp", "raw", "ws"].contains(transport),
                  ["none", ""].contains(fields["headerType"] ?? "none"),
                  ["none", ""].contains(fields["encryption"] ?? "none") else {
                throw BywayError.message(L10n.text("此版本支持 TCP / RAW VLESS"))
            }
            let flow = fields["flow"] ?? ""
            guard ["", "xtls-rprx-vision"].contains(flow) else {
                throw BywayError.message(L10n.text("VLESS 流控类型不受支持"))
            }
            options["uuid"] = uuid.uuidString.lowercased()
            if transport == "ws" {
                guard flow.isEmpty else { throw BywayError.message(L10n.text("WebSocket 节点不可使用 VLESS Vision 流控")) }
                options["transport"] = Self.webSocket(path: fields["path"], host: fields["host"])
            }
            if !flow.isEmpty { options["flow"] = flow }
            options["tls"] = try Self.tlsConfiguration(fields: fields, host: host)
        default:
            throw BywayError.message(L10n.text("支持 VLESS、VMess、Shadowsocks 和 SOCKS5 链接"))
        }
        self.outbound = try JSONSerialization.data(withJSONObject: options, options: [.sortedKeys])
    }

    private static func nodeURL(_ text: String) -> URLComponents? {
        guard text.lowercased().hasPrefix("ss://") else { return URLComponents(string: text) }
        let parts = text.dropFirst(5).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let resource = parts.first else { return nil }
        if resource.contains("@") { return URLComponents(string: text) }

        // Older clients encode both the credentials and server into a single Base64 string.
        guard let decoded = decodeBase64(String(resource)), let at = decoded.lastIndex(of: "@"),
              let colon = decoded[..<at].firstIndex(of: ":"),
              var url = URLComponents(string: "ss://" + decoded[decoded.index(after: at)...]),
              url.user == nil, url.query == nil, url.fragment == nil else { return nil }
        url.user = String(decoded[..<colon])
        url.password = String(decoded[decoded.index(after: colon)..<at])
        if parts.count == 2 { url.fragment = parts[1].removingPercentEncoding }
        return url
    }

    private static func decodeBase64(_ string: String) -> String? {
        let encoded = (string.removingPercentEncoding ?? string)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
        return Data(base64Encoded: encoded + padding).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func configureShadowsocks(_ url: URLComponents, fields: [String: String],
                                           options: inout [String: Any]) throws {
        guard let user = url.user, ["", "/"].contains(url.path) else {
            throw BywayError.message(L10n.text("Shadowsocks 链接缺少加密方式或密码"))
        }
        let credentials = url.password.map { [user, $0] }
            ?? decodeBase64(user)?.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let credentials, credentials.count == 2, !credentials[1].isEmpty else {
            throw BywayError.message(L10n.text("Shadowsocks 链接缺少加密方式或密码"))
        }
        let method = credentials[0].lowercased()
        let supported = ["aes-128-gcm", "aes-192-gcm", "aes-256-gcm", "chacha20-ietf-poly1305",
                         "xchacha20-ietf-poly1305", "2022-blake3-aes-128-gcm",
                         "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305"]
        guard supported.contains(method) else { throw BywayError.message(L10n.text("此 Shadowsocks 加密方式不受支持")) }
        if method.hasPrefix("2022-") {
            let keyLength = method == "2022-blake3-aes-128-gcm" ? 16 : 32
            let keys = credentials[1].split(separator: ":", omittingEmptySubsequences: false)
            guard keys.allSatisfy({ Data(base64Encoded: String($0))?.count == keyLength }),
                  method != "2022-blake3-chacha20-poly1305" || keys.count == 1 else {
                throw BywayError.message(L10n.text("Shadowsocks 2022 密钥格式无效"))
            }
        }
        options["type"] = "shadowsocks"
        options["method"] = method
        options["password"] = credentials[1]
        if let plugin = fields["plugin"] {
            let parts = plugin.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first, ["obfs-local", "v2ray-plugin"].contains(String(name)) else {
                throw BywayError.message(L10n.text("此 Shadowsocks 插件不受支持"))
            }
            options["plugin"] = String(name)
            if parts.count == 2 { options["plugin_opts"] = String(parts[1]) }
        }
    }

    func updating(link: String?, name: String?) throws -> Self {
        if let link { return try Self(link: link, id: id, name: name ?? self.name) }
        let name = try name.map(Self.validName) ?? self.name
        return Self(id: id, name: name, host: host, port: port, outbound: outbound)
    }

    func hasSameEndpoint(as other: Self) -> Bool { outbound == other.outbound }

    func withID(_ id: UUID) -> Self { Self(id: id, name: name, host: host, port: port, outbound: outbound) }

    var protocolName: String { (try? outboundConfiguration["type"] as? String) ?? "" }

    private static func webSocket(path: String?, host: String?) -> [String: Any] {
        var transport: [String: Any] = ["type": "ws", "path": path?.nonEmpty ?? "/"]
        if let host = host?.nonEmpty { transport["headers"] = ["Host": host] }
        return transport
    }

    private static func vmess(_ link: String, id: UUID, name: String?) throws -> Self {
        guard link.utf8.count <= 4096, let data = NodeImport.decodeBase64(String(link.dropFirst(8))),
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BywayError.message(L10n.text("VMess 链接无法读取"))
        }
        func text(_ key: String) -> String { fields[key].map { String(describing: $0) } ?? "" }
        let host = text("add").trimmingCharacters(in: ["[", "]"])
        let network = text("net").nonEmpty ?? "tcp"
        let tls = text("tls")
        let alterID = Int(text("aid").nonEmpty ?? "0")
        let cipher = text("scy").nonEmpty ?? "auto"
        guard !host.isEmpty, let port = Int(text("port")), (1...65535).contains(port),
              let uuid = UUID(uuidString: text("id")), let alterID, (0...65535).contains(alterID),
              ["tcp", "raw", "ws"].contains(network), ["", "none"].contains(text("type")),
              ["", "none", "tls"].contains(tls), ["auto", "none", "zero", "aes-128-gcm", "chacha20-poly1305", "aes-128-ctr"].contains(cipher) else {
            throw BywayError.message(L10n.text("VMess 节点参数无效，支持 TCP / WebSocket"))
        }
        var options: [String: Any] = ["type": "vmess", "server": host, "server_port": port,
                                      "uuid": uuid.uuidString.lowercased(), "security": cipher, "alter_id": alterID]
        if network == "ws" { options["transport"] = webSocket(path: text("path"), host: text("host")) }
        if tls == "tls" {
            options["tls"] = try tlsConfiguration(fields: ["security": tls, "sni": text("sni").nonEmpty ?? text("host"),
                                                           "fp": text("fp"), "alpn": text("alpn")], host: host)
        }
        return Self(id: id, name: try name.map(validName) ?? String((text("ps").nonEmpty ?? host).prefix(80)),
                    host: host, port: port, outbound: try JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]))
    }

    private init(id: UUID, name: String, host: String, port: Int, outbound: Data) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.outbound = outbound
    }

    private static func validName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.count), name.utf8.count <= 320,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw BywayError.message(L10n.text("节点名称需要 1 至 80 个字符"))
        }
        return name
    }

    private static func tlsConfiguration(fields: [String: String], host: String) throws -> [String: Any]? {
        let security = fields["security"] ?? "none"
        guard security != "none" else { return nil }
        guard ["tls", "reality"].contains(security), fields["allowInsecure"] != "1" else {
            throw BywayError.message(L10n.text("TLS 安全设置不受支持"))
        }
        var tls: [String: Any] = ["enabled": true, "server_name": fields["sni"]?.nonEmpty ?? host]
        if let alpn = fields["alpn"]?.nonEmpty {
            tls["alpn"] = alpn.split(separator: ",").map(String.init)
        }
        if security == "reality" {
            guard let publicKey = fields["pbk"], !publicKey.isEmpty else {
                throw BywayError.message(L10n.text("REALITY 节点需要公钥"))
            }
            tls["reality"] = ["enabled": true, "public_key": publicKey, "short_id": fields["sid"] ?? ""]
        }
        if let fingerprint = fields["fp"]?.nonEmpty ?? (security == "reality" ? "chrome" : nil) {
            tls["utls"] = ["enabled": true, "fingerprint": fingerprint]
        }
        return tls
    }
}

struct RelayConfiguration: Codable, Equatable, Sendable {
    let address: URL
    let deviceKey: String

    init(address: String, deviceKey: String) throws {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: text), parts.scheme == "https", let url = parts.url,
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else {
            throw BywayError.message(L10n.text("请输入控制服务的 HTTPS 地址"))
        }
        let key = deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32...128).contains(key.utf8.count),
              key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw BywayError.message(L10n.text("设备密钥至少需要 32 个字符"))
        }
        self.address = url
        self.deviceKey = key
    }

    var exchangeURL: URL {
        address.appending(path: "device/exchange")
    }
}

/// 代理内核的入站方式。iOS 由 VPN 扩展提供 TUN，macOS 在进程内使用本机混合端口。
enum EngineInbound: Equatable, Sendable {
    case tun
    case mixed(port: Int)
}

struct BywayProfile: Codable, Equatable, Sendable {
    var nodes: [ProxyNode] = []
    var selectedID: UUID?
    var relay: RelayConfiguration?
    var routing: ProxyRouting?
    var importedConfiguration: ImportedConfiguration?
    var routingLibrary: RoutingLibrary?
    var subscriptions: [NodeSubscription]?
    var globalRouting: GlobalRouting?
    var dns: DNSSettings?
    var privateNetwork: PrivateNetworkSettings?

    var routingSettings: ProxyRouting { routing ?? ProxyRouting() }
    var globalRoutingSettings: GlobalRouting { globalRouting ?? GlobalRouting() }
    var dnsSettings: DNSSettings { dns ?? DNSSettings() }

    var selected: ProxyNode? {
        nodes.first { $0.id == selectedID } ?? nodes.first
    }

    func routingCandidates(on network: RoutingNetwork) -> [ProxyNode] {
        globalRoutingSettings.candidates(in: globalRoutingSettings.decision(on: network), nodes: nodes)
    }

    func selected(on network: RoutingNetwork, preferredID: UUID?) -> ProxyNode? {
        let candidates = routingCandidates(on: network)
        return candidates.first { $0.id == preferredID } ?? candidates.first
    }

    func engineConfiguration(geoIPPath: String? = Bundle.main.path(forResource: "geoip-cn", ofType: "srs"),
                             network: RoutingNetwork = .other, privateStateRoot: URL? = nil,
                             inbound: EngineInbound = .tun) throws -> String {
        let candidates = routingCandidates(on: network)
        let selected = candidates.first(where: { $0.id == selectedID }) ?? candidates.first
        guard selected != nil || privateNetwork != nil && nodes.isEmpty else {
            throw BywayError.message(L10n.text("请先添加代理节点"))
        }
        let selector: [[String: Any]] = selected.map { selected in
            [["type": "selector", "tag": "byway", "outbounds": candidates.map(\.tag),
              "default": selected.tag, "interrupt_exist_connections": true]]
        } ?? []
        let privateEnabled = privateNetwork?.enabled == true
        let proxyTag = selected == nil ? "direct" : "byway"
        let routing = routingSettings
        let imported = try importedConfiguration.flatMap {
            $0.enabled ? try RoutingImportDocument($0.text).parsed : nil
        }
        let mode = globalRoutingSettings.decision(on: network).mode
        let exit: String
        switch mode {
        case .proxy: exit = proxyTag
        case .direct: exit = "direct"
        case .rules, .scene:
            let configuredExit = imported?.final.outbound ?? (routing.defaultRoute == .proxy ? "byway" : "direct")
            exit = configuredExit == "byway" ? proxyTag : configuredExit
        }
        var rules: [[String: Any]] = [
            ["action": "sniff", "timeout": "200ms"],
            ["protocol": "dns", "action": "hijack-dns"]
        ]
        if privateEnabled {
            rules.append(["inbound": PrivateNetworkSettings.tag, "action": "reject"])
            rules.append(["preferred_by": PrivateNetworkSettings.tag, "action": "route", "outbound": PrivateNetworkSettings.tag])
        }
        if let privateNetwork {
            if !privateNetwork.lastAddresses.isEmpty {
                rules.append(["ip_cidr": privateNetwork.lastAddresses, "action": "reject"])
            }
            if let suffix = privateNetwork.lastDNSSuffix {
                rules.append(["domain_suffix": suffix, "action": "reject"])
            }
        }
        if let host = relay?.address.host() {
            rules.append(["domain": host, "action": "route", "outbound": "direct"])
        }
        if let imported {
            if !imported.ipv6 { rules.append(["ip_version": 6, "action": "reject"]) }
            if mode == .rules {
                rules += imported.engineRules().map { rule in
                    guard selected == nil, rule["outbound"] as? String == "byway" else { return rule }
                    var directRule = rule
                    directRule["outbound"] = "direct"
                    return directRule
                }
                if imported.final == .reject { rules.append(["action": "reject"]) }
            }
        } else {
            if routing.bypassPrivateNetworks {
                rules.append(["ip_is_private": true, "action": "route", "outbound": "direct"])
            }
            if mode == .rules, !routing.directDomains.isEmpty {
                rules.append(["domain_suffix": routing.directDomains, "action": "route", "outbound": "direct"])
            }
        }
        var route: [String: Any] = [
            "auto_detect_interface": true, "default_domain_resolver": "bootstrap",
            "final": exit, "rules": rules
        ]
        if mode == .rules, imported?.usesGeoIP == true {
            guard let geoIPPath else { throw BywayError.message(L10n.text("缺少 GEOIP,CN 数据")) }
            route["rule_set"] = [["type": "local", "tag": "geoip-cn", "format": "binary", "path": geoIPPath]]
        }
        var inboundConfiguration: [String: Any]
        switch inbound {
        case .tun:
            // IPv6 地址只在配置确实要求 IPv6 时才挂进 TUN。
            // 之前无条件分配 fd3b:a18e:a7e9::1/126：系统把 IPv6 流量全送进隧道，
            // 而节点的 IPv6 出站通常不可用，IPv6 于是变成黑洞——浏览器优先 IPv6，
            // 整站打不开，curl 回退 IPv4 却看起来一切正常，极难定位。
            var tunAddress = ["172.28.80.1/30"]
            if imported?.ipv6 ?? false { tunAddress.append("fd3b:a18e:a7e9::1/126") }
            var tun: [String: Any] = [
                "type": "tun", "tag": "tun-in", "auto_route": true, "stack": "gvisor",
                "address": tunAddress, "mtu": 1400
            ]
            if privateEnabled {
                tun["route_address"] = PrivateNetworkSettings.addressRanges.map(\.0)
            }
            if let imported {
                let excluded = privateEnabled
                    ? imported.excludedRoutes.filter { !PrivateNetworkSettings.excludesPrivateAddress($0) }
                    : imported.excludedRoutes
                if !excluded.isEmpty { tun["route_exclude_address"] = excluded }
            }
            inboundConfiguration = tun
        case .mixed(let port):
            inboundConfiguration = [
                "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": port
            ]
        }
        let direct: [String: Any] = ["type": "direct", "tag": "direct"]
        var configuration: [String: Any] = [
            // 内核日志级别：全流量接管出问题时，warn 会把「为什么连不上」全部吞掉。
            "log": ["level": inbound == .tun ? "info" : "warn"],
            "dns": try dnsConfiguration(imported: imported, exit: exit),
            "inbounds": [inboundConfiguration],
            "outbounds": selector + [direct] + (try nodes.map { try $0.outboundConfiguration }),
            "route": route
        ]
        if privateEnabled, let privateNetwork, let privateStateRoot {
            configuration["endpoints"] = [privateNetwork.endpoint(in: privateStateRoot)]
        } else if privateEnabled {
            throw BywayError.message(L10n.text("私网身份目录不可用"))
        }
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func dnsConfiguration(imported: ShadowrocketConfiguration?, exit: String) throws -> [String: Any] {
        let settings = dnsSettings
        let resolver = settings.mode == .configuration ? imported?.dnsServer : nil
        let usesLegacyDNS = settings.mode == .configuration && routingSettings.dnsServer != ProxyRouting.defaultDNSServer
        var bootstrap: [String: Any] = ["type": "local", "tag": "bootstrap"]
        if resolver == "system" { bootstrap["prefer_go"] = true }
        var servers = [bootstrap]
        var rules: [[String: Any]] = []
        var dns: [String: Any] = ["final": "bootstrap"]
        if settings.mode == .manual {
            guard let server = settings.selected else { throw BywayError.message(L10n.text("请选择加密 DNS")) }
            servers.append(try server.engineConfiguration(tag: "tunnel-dns", exit: exit))
            dns["final"] = "tunnel-dns"
        } else if resolver == nil, !usesLegacyDNS {
            let tags = settings.servers.indices.map { "tunnel-dns-\($0)" }
            for (server, tag) in zip(settings.servers, tags) {
                servers.append(try server.engineConfiguration(tag: tag, exit: exit))
            }
            servers.append(["type": "byway-dns", "tag": "auto-dns", "servers": tags, "exit": exit])
            dns["final"] = "auto-dns"
        } else if resolver != "system" {
            var primary: [String: Any] = [
                "type": "https", "tag": "tunnel-dns", "server": routingSettings.dnsServer,
                "domain_resolver": "bootstrap", "detour": exit
            ]
            if let resolver {
                if let url = URLComponents(string: resolver), url.scheme == "https", let host = url.host {
                    primary["server"] = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    if let port = url.port { primary["server_port"] = port }
                    if !url.percentEncodedPath.isEmpty { primary["path"] = url.percentEncodedPath }
                } else {
                    primary["type"] = "udp"
                    primary["server"] = resolver
                }
            }
            servers.append(primary)
            dns["final"] = "tunnel-dns"
        }
        if let imported {
            dns["reverse_mapping"] = true
            if !imported.hosts.isEmpty {
                servers.append(["type": "hosts", "tag": "imported-hosts", "predefined": imported.hosts])
                rules.append(["domain": imported.hosts.keys.sorted(), "action": "route", "server": "imported-hosts"])
            }
            dns["strategy"] = imported.ipv6 ? imported.preferIP : "ipv4_only"
        }
        if privateNetwork?.enabled == true {
            servers.append(["type": "tailscale", "tag": PrivateNetworkSettings.dnsTag, "endpoint": PrivateNetworkSettings.tag])
            rules.insert(["preferred_by": PrivateNetworkSettings.dnsTag, "action": "route",
                          "server": PrivateNetworkSettings.dnsTag], at: 0)
        }
        if let suffix = privateNetwork?.lastDNSSuffix {
            rules.insert(["domain_suffix": suffix, "action": "reject"], at: privateNetwork?.enabled == true ? 1 : 0)
        }
        if !rules.isEmpty { dns["rules"] = rules }
        dns["servers"] = servers
        return dns
    }
}

struct ProxyRouting: Codable, Equatable, Sendable {
    enum DefaultRoute: String, Codable, Sendable { case proxy, direct }

    static let defaultDNSServer = "1.1.1.1"

    var defaultRoute: DefaultRoute = .proxy
    var dnsServer = Self.defaultDNSServer
    var bypassPrivateNetworks = true
    var directDomains: [String] = []

    func validated() throws -> Self {
        var result = self
        result.dnsServer = dnsServer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard IPv4Address(result.dnsServer) != nil || IPv6Address(result.dnsServer) != nil ||
            Self.isDomain(result.dnsServer) else {
            throw BywayError.message(L10n.text("DNS 服务器需要 IP 地址或域名"))
        }
        result.directDomains = directDomains.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard result.directDomains.count <= 32, result.directDomains.allSatisfy(Self.isDomain) else {
            throw BywayError.message(L10n.text("直连域名最多 32 个，请填写有效域名"))
        }
        return result
    }

    static func isDomain(_ name: String) -> Bool {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, name.utf8.count <= 253 else { return false }
        return labels.allSatisfy { label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}

struct NodeStatus: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
}

struct TunnelStatus: Codable, Equatable, Sendable {
    let connected: Bool
    let selectedNodeID: UUID?
    let nodes: [NodeStatus]
}

enum Operation: String, Codable, Sendable {
    case status, probe, select
}

struct Command: Codable, Sendable {
    let id: UUID
    let operation: Operation
    let nodeID: UUID?
    let expiresAt: Double?

    init(_ operation: Operation, nodeID: UUID? = nil) {
        id = UUID()
        self.operation = operation
        self.nodeID = nodeID
        expiresAt = nil
    }
}

struct Probe: Codable, Equatable, Sendable {
    let latencyMS: Int
    let exitIP: String
}

struct CommandResult: Codable, Sendable {
    let id: UUID
    let status: TunnelStatus
    let probe: Probe?
    let error: String?
}

struct DeviceExchange: Codable, Sendable {
    let status: TunnelStatus
    let completion: CommandResult?
}

struct RelayReply: Codable, Sendable {
    let command: Command?
    let acknowledged: UUID?
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
