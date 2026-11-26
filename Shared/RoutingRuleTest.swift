import Foundation
import Network
import zlib

struct RoutingRuleMatch: Codable, Sendable {
    let policy: String
    let rule: String
    let lineNumber: Int?
    let nodeName: String?
    let resolvedAddresses: [String]
}

extension ShadowrocketConfiguration {
    static func inserting(_ rule: String, into text: String) throws -> String {
        guard !rule.contains(where: \.isNewline),
              try ShadowrocketConfiguration("[Rule]\n" + rule).rules.count == 1 else {
            throw LANFailure(422, L10n.text("请提供一条有效的域名或 IP 规则"))
        }
        var lines = text.components(separatedBy: "\n")
        guard let section = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{feff}"])).lowercased() == "[rule]"
        }) else { throw LANFailure(422, L10n.text("缺少 [Rule]")) }
        if section + 1 < lines.count && lines[section + 1].trimmingCharacters(in: .whitespacesAndNewlines) == rule {
            return text
        }
        lines.insert(rule + (lines[section].hasSuffix("\r") ? "\r" : ""), at: section + 1)
        let updated = lines.joined(separator: "\n")
        _ = try ShadowrocketConfiguration(updated)
        return updated
    }

    func test(host input: String, node: String?, port: Int? = nil,
              resolving: (String) -> [String] = Self.resolve) throws -> RoutingRuleMatch {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = text.hasSuffix(".") ? String(text.dropLast()) : text
        let literal = Self.ip(host)
        guard literal != nil || URLComponents(string: "https://" + host)?.host == host &&
                !host.isEmpty && host.utf8.count <= 253 else {
            throw LANFailure(422, L10n.text("请输入域名或 IP 地址"))
        }
        var resolved = literal == nil ? [] : [host]
        var didResolve = literal != nil
        if literal?.count == 16 && !ipv6 {
            return result(.reject, rule: L10n.text("IPv6 已禁用"), line: nil)
        }
        for rule in rules {
            let matched: Bool
            switch rule.kind {
            case .domain:
                matched = literal == nil && host == rule.value
            case .suffix:
                matched = literal == nil && (host == rule.value || host.hasSuffix("." + rule.value))
            case .keyword:
                matched = literal == nil && host.contains(rule.value)
            case .port:
                matched = port.flatMap { Rule.ports(rule.value)?.contains($0) } == true
            case .ipv4, .ipv6, .geoIP:
                if !didResolve && !rule.noResolve {
                    didResolve = true
                    resolved = hosts[host] ?? resolving(host)
                    if !ipv6 { resolved = resolved.filter { Self.ip($0)?.count == 4 } }
                }
                if rule.kind == .geoIP, !resolved.isEmpty {
                    guard let database = GeoIPChina.database else {
                        throw LANFailure(503, L10n.text("当前设备缺少 GEOIP,CN 数据"))
                    }
                    matched = resolved.compactMap(Self.ip).contains { database.contains($0) }
                } else {
                    matched = resolved.contains { Self.matches($0, cidr: rule.value) }
                }
            }
            if matched {
                let raw = "\(rule.kind.rawValue),\(rule.value),\(rule.policy.rawValue)" + (rule.noResolve ? ",no-resolve" : "")
                return result(rule.policy, rule: raw, line: rule.lineNumber)
            }
        }
        return result(final, rule: "FINAL,\(final.rawValue)", line: finalLine)

        func result(_ policy: Policy, rule: String, line: Int?) -> RoutingRuleMatch {
            RoutingRuleMatch(policy: policy.rawValue, rule: rule, lineNumber: line,
                             nodeName: policy == .proxy ? node : nil, resolvedAddresses: resolved)
        }
    }

    static func defaultTest(host: String, routing: ProxyRouting, node: String?) throws -> RoutingRuleMatch {
        let suffixes = routing.directDomains.map { "DOMAIN-SUFFIX,\($0),DIRECT" }
        if routing.bypassPrivateNetworks && isPrivateAddress(host) {
            return RoutingRuleMatch(policy: "DIRECT", rule: L10n.text("私有网络直连"), lineNumber: nil, nodeName: nil, resolvedAddresses: [host])
        }
        return try ShadowrocketConfiguration((["[Rule]"] + suffixes +
            ["FINAL,\(routing.defaultRoute == .proxy ? "PROXY" : "DIRECT")"]).joined(separator: "\n")).test(host: host, node: node)
    }

    private static func isPrivateAddress(_ text: String) -> Bool {
        ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16",
         "100.64.0.0/10", "::1/128", "fc00::/7", "fe80::/10"].contains { matches(text, cidr: $0) }
    }

    private static func ip(_ text: String) -> Data? {
        IPv4Address(text)?.rawValue ?? IPv6Address(text)?.rawValue
    }

    static func matches(_ address: String, cidr: String) -> Bool {
        let fields = cidr.split(separator: "/")
        guard fields.count == 2, let prefix = Int(fields[1]), let ip = ip(address),
              let network = Self.ip(String(fields[0])), ip.count == network.count, (0...ip.count * 8).contains(prefix) else { return false }
        let bytes = prefix / 8
        guard ip.prefix(bytes).elementsEqual(network.prefix(bytes)) else { return false }
        let bits = prefix % 8
        if bits == 0 { return true }
        let mask = UInt8.max << (8 - bits)
        return ip[bytes] & mask == network[bytes] & mask
    }

    static func resolve(_ host: String) -> [String] {
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, nil, &first) == 0, let first else { return [] }
        defer { freeaddrinfo(first) }
        var address: UnsafeMutablePointer<addrinfo>? = first
        var values: [String] = []
        while let current = address {
            let item = current.pointee
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(item.ai_addr, item.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: name)
                if !values.contains(value), ip(value) != nil { values.append(value) }
            }
            address = item.ai_next
        }
        return values
    }
}

private struct GeoIPChina: Sendable {
    // The bundled SRS is a single version-1 IP-set rule. Refuse other layouts
    // instead of guessing when the resource changes.
    static let database: GeoIPChina? = Bundle.main.url(forResource: "geoip-cn", withExtension: "srs")
        .flatMap { try? Data(contentsOf: $0) }.flatMap(Self.init)
    let ranges: [(Data, Data)]

    init?(_ source: Data) {
        guard source.prefix(4).elementsEqual([0x53, 0x52, 0x53, 1]) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 1024 * 1024)
        var length = uLong(bytes.count)
        let status = source.dropFirst(4).withUnsafeBytes { input in
            uncompress(&bytes, &length, input.bindMemory(to: UInt8.self).baseAddress, uLong(input.count))
        }
        guard status == Z_OK, length > 14, bytes.prefix(4).elementsEqual([1, 0, 6, 1]) else { return nil }
        let count = bytes[4..<12].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard count <= 100_000 else { return nil }
        var index = 12
        var ranges: [(Data, Data)] = []
        for _ in 0..<count {
            guard let from = read(), let to = read(), from.count == to.count else { return nil }
            ranges.append((from, to))
        }
        guard index + 2 == length, bytes[index] == 255, bytes[index + 1] == 0 else { return nil }
        self.ranges = ranges

        func read() -> Data? {
            guard index < length else { return nil }
            let size = Int(bytes[index])
            index += 1
            guard size == 4 || size == 16, index + size <= length else { return nil }
            defer { index += size }
            return Data(bytes[index ..< index + size])
        }
    }

    func contains(_ ip: Data) -> Bool {
        ranges.contains { start, end in
            start.count == ip.count && !ip.lexicographicallyPrecedes(start) && !end.lexicographicallyPrecedes(ip)
        }
    }
}
