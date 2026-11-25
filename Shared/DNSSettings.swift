import Foundation
import Network

struct DNSServer: Codable, Equatable, Sendable, Identifiable {
    var id = UUID().uuidString
    var name = ""
    var address = ""
    var connectionIP: String?

    func validated() throws -> Self {
        var server = self
        server.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        server.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        server.connectionIP = connectionIP?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        guard (1...64).contains(server.name.count), (1...64).contains(server.id.utf8.count) else {
            throw BywayError.message("请输入 DNS 名称，最多 64 个字符")
        }
        guard let endpoint = server.endpoint else {
            throw BywayError.message("请输入有效的 HTTPS DNS 地址，如 https://dns.google/dns-query")
        }
        server.address = endpoint.string ?? server.address
        if let ip = server.connectionIP, IPv4Address(ip) == nil, IPv6Address(ip) == nil {
            throw BywayError.message("连接地址需要有效的 IPv4 或 IPv6 地址")
        }
        return server
    }

    private var endpoint: URLComponents? {
        guard address.utf8.count <= 2048, var url = URLComponents(string: address),
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        let hostname = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard IPv4Address(hostname) != nil || IPv6Address(hostname) != nil || ProxyRouting.isDomain(hostname) else {
            return nil
        }
        url.scheme = "https"
        url.host = host
        if url.port == 443 { url.port = nil }
        if url.path.isEmpty { url.path = "/dns-query" }
        return url
    }

    func engineConfiguration(tag: String, exit: String) throws -> [String: Any] {
        guard let endpoint, let host = endpoint.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else {
            throw BywayError.message("加密 DNS 地址无效")
        }
        var options: [String: Any] = ["type": "https", "tag": tag, "server": connectionIP ?? host,
                                     "path": endpoint.percentEncodedPath, "domain_resolver": "bootstrap", "detour": exit]
        if let port = endpoint.port { options["server_port"] = port }
        if connectionIP != nil { options["tls"] = ["server_name": host] }
        return options
    }
}

struct DNSSettings: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case configuration, automatic, manual

        var id: Self { self }
        var title: String {
            switch self {
            case .configuration: "跟随分流配置"
            case .automatic: "自动选择"
            case .manual: "手动指定"
            }
        }
    }

    static let presets = [
        DNSServer(id: "cloudflare", name: "Cloudflare", address: "https://cloudflare-dns.com/dns-query", connectionIP: "1.1.1.1"),
        DNSServer(id: "alidns", name: "AliDNS", address: "https://dns.alidns.com/dns-query", connectionIP: "223.5.5.5"),
        DNSServer(id: "dnspod", name: "DNSPod", address: "https://doh.pub/dns-query", connectionIP: "120.53.53.53"),
        DNSServer(id: "google", name: "Google", address: "https://dns.google/dns-query", connectionIP: "8.8.8.8")
    ]
    static let maxServers = 8

    var mode: Mode = .configuration
    var servers = Self.presets
    var selectedID: String? = Self.presets.first?.id

    var selected: DNSServer? { servers.first { $0.id == selectedID } }

    func validated() throws -> Self {
        guard (1...Self.maxServers).contains(servers.count) else {
            throw BywayError.message("请保留 1 至 \(Self.maxServers) 个加密 DNS")
        }
        var settings = self
        settings.servers = try servers.map { try $0.validated() }
        let ids = Set(settings.servers.map(\.id))
        let addresses = Set(settings.servers.map { [$0.address, $0.connectionIP ?? ""] })
        guard ids.count == servers.count, addresses.count == servers.count else {
            throw BywayError.message("请移除重复的 DNS 地址")
        }
        if mode == .manual, settings.selected == nil {
            throw BywayError.message("请选择要使用的 DNS 服务器")
        }
        if settings.selected == nil { settings.selectedID = settings.servers.first?.id }
        return settings
    }
}

struct DNSUpdate: Codable, Sendable {
    let dnsSettings: DNSSettings
}

struct DNSUpdateReply: Codable, Sendable {
    var settings: DNSSettings?
    var error: String?
}
