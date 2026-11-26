import Foundation
import Network

struct ImportedConfiguration: Codable, Equatable, Sendable {
    var text: String
    var enabled: Bool

    func report() throws -> ImportedConfigurationReport {
        let imported = try RoutingImportDocument(text)
        let configuration = imported.parsed
        return ImportedConfigurationReport(enabled: enabled, ruleCount: configuration.rules.count,
                                           warnings: imported.warnings + configuration.warnings)
    }
}

struct ImportedConfigurationReport: Encodable, Sendable {
    let enabled: Bool
    let ruleCount: Int
    let warnings: [String]
}

struct ShadowrocketConfiguration: Sendable {
    static let maxBytes = 1024 * 1024

    enum Policy: String, Sendable {
        case direct = "DIRECT", proxy = "PROXY", reject = "REJECT"

        var outbound: String { self == .direct ? "direct" : "byway" }
    }

    struct Rule: Sendable {
        enum Kind: String, CaseIterable, Sendable {
            case domain = "DOMAIN", suffix = "DOMAIN-SUFFIX", keyword = "DOMAIN-KEYWORD"
            case ipv4 = "IP-CIDR", ipv6 = "IP-CIDR6", geoIP = "GEOIP", port = "DST-PORT"

            var field: String {
                switch self {
                case .domain: "domain"
                case .suffix: "domain_suffix"
                case .keyword: "domain_keyword"
                case .ipv4, .ipv6: "ip_cidr"
                case .geoIP: "rule_set"
                case .port: "port"
                }
            }
        }

        let kind: Kind
        let value: String
        let policy: Policy
        let noResolve: Bool
        let lineNumber: Int

        var engineRule: [String: Any] {
            var rule: [String: Any] = [kind.field: [kind == .geoIP ? "geoip-cn" : value]]
            if kind == .port, let ports = Self.ports(value) {
                rule = ports.lowerBound == ports.upperBound
                    ? ["port": [ports.lowerBound]]
                    : ["port_range": ["\(ports.lowerBound):\(ports.upperBound)"]]
            }
            if policy == .reject {
                rule["action"] = "reject"
            } else {
                rule["action"] = "route"
                rule["outbound"] = policy.outbound
                if kind == .domain, policy == .proxy {
                    // Let the proxy resolve exact domains even when the system answer was unusable.
                    rule["override_address"] = value
                }
            }
            return rule
        }

        static func ports(_ value: String) -> ClosedRange<Int>? {
            let fields = value.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(fields.count),
                  let first = Int(fields[0].trimmingCharacters(in: .whitespaces)),
                  let last = Int(fields[fields.count - 1].trimmingCharacters(in: .whitespaces)),
                  1 <= first, first <= last, last <= 65535 else { return nil }
            return first...last
        }
    }

    private(set) var rules: [Rule] = []
    private(set) var excludedRoutes: [String] = []
    private(set) var hosts: [String: [String]] = [:]
    private(set) var final = Policy.proxy
    private(set) var finalLine: Int?
    private(set) var dnsServer: String?
    private(set) var preferIP: String?
    /// 默认关闭：全流量 TUN 下劫持 IPv6 却没有可用出口，IPv6 会成为黑洞，
    /// 导致浏览器优先 IPv6 时整站打不开。配置里显式写 `ipv6 = true` 才会启用。
    private(set) var ipv6 = false
    private(set) var warnings: [String] = []

    var usesGeoIP: Bool { rules.contains { $0.kind == .geoIP } }

    init(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= Self.maxBytes else {
            throw BywayError.message(L10n.text("配置需要为 UTF-8 文本，大小不能超过 1 MB"))
        }
        var section = ""
        var hasRuleSection = false
        var hasFinal = false
        var hasRewrite = false
        var fallbackDNS: String?
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{feff}"]))
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = line.dropFirst().dropLast().lowercased()
                if section == "rule" { hasRuleSection = true }
                if !["general", "rule", "host", "url rewrite"].contains(section) {
                    warn(L10n.text("配置段 [{0}] 已保留，当前版本不执行", section))
                }
                continue
            }

            let lineNumber = index + 1
            switch section {
            case "general":
                let (key, value) = try Self.assignment(line, at: lineNumber)
                switch key {
                case "dns-server":
                    dnsServer = try Self.resolver(value, at: lineNumber)
                case "fallback-dns-server":
                    fallbackDNS = value
                case "ipv6":
                    ipv6 = try Self.flag(value, at: lineNumber)
                case "prefer-ipv6":
                    preferIP = try Self.flag(value, at: lineNumber) ? "prefer_ipv6" : "prefer_ipv4"
                case "tun-excluded-routes":
                    excludedRoutes = try Self.values(value).map { try Self.cidr($0, at: lineNumber) }
                case "always-real-ip":
                    // Byway's DNS uses real IP responses for every domain.
                    break
                case "private-ip-answer":
                    if try !Self.flag(value, at: lineNumber) { warn(L10n.text("Byway 保留 DNS 返回的私有 IP 地址")) }
                case "udp-policy-not-supported-behaviour":
                    if value.uppercased() != "REJECT" { warn(L10n.text("不支持 UDP 的节点保持拒绝处理")) }
                case "dns-direct-system":
                    if try Self.flag(value, at: lineNumber) { warn(L10n.text("直连域名沿用导入后的统一 DNS 设置")) }
                default:
                    warn(L10n.text("设置 {0} 已保留，当前版本不执行", key))
                }
            case "rule":
                let fields = Self.values(line)
                let kind = fields[0].uppercased()
                if hasFinal {
                    throw Self.invalid(lineNumber, L10n.text("FINAL 后还有分流规则"))
                } else if kind == "FINAL" {
                    guard fields.count == 2, let policy = Policy(rawValue: fields[1].uppercased()) else {
                        throw Self.invalid(lineNumber, L10n.text("FINAL 需要指定 DIRECT、PROXY 或 REJECT"))
                    }
                    final = policy
                    finalLine = lineNumber
                    hasFinal = true
                } else if let kind = Rule.Kind(rawValue: kind) {
                    if let rule = try parseRule(fields, kind: kind, at: lineNumber) { rules.append(rule) }
                } else {
                    warn(L10n.text("第 {0} 行 {1} 已保留，当前版本不执行", lineNumber, kind))
                }
            case "host":
                let (host, value) = try Self.assignment(line, at: lineNumber)
                let addresses = Self.values(value)
                guard Self.isHostname(host), addresses.allSatisfy({ IPv4Address($0) != nil || IPv6Address($0) != nil }) else {
                    throw Self.invalid(lineNumber, L10n.text("Host 需要有效的主机名和 IP 地址"))
                }
                guard hosts[host] == nil else { throw Self.invalid(lineNumber, L10n.text("Host 重复定义")) }
                hosts[host] = addresses
            case "url rewrite":
                hasRewrite = true
            default:
                break
            }
        }
        guard hasRuleSection, hasFinal || !rules.isEmpty else { throw BywayError.message(L10n.text("请提供带有 [Rule] 的分流配置")) }
        if let fallbackDNS, fallbackDNS.lowercased() != dnsServer?.lowercased() {
            warn(L10n.text("备用 DNS 已保留，当前版本只使用主 DNS"))
        }
        if hasRewrite { warn(L10n.text("[URL Rewrite] 已保留，当前版本不执行网址跳转")) }
    }

    func engineRules() -> [[String: Any]] {
        var result: [[String: Any]] = []
        var resolved = false
        for rule in rules {
            if !resolved, !rule.noResolve, [.ipv4, .ipv6, .geoIP].contains(rule.kind) {
                result.append(["action": "resolve"])
                resolved = true
            }
            result.append(rule.engineRule)
        }
        return result
    }

    private mutating func parseRule(_ fields: [String], kind: Rule.Kind, at line: Int) throws -> Rule? {
        let isIP = kind == .ipv4 || kind == .ipv6
        guard fields.count == 3 || (isIP && fields.count == 4 && fields[3].lowercased() == "no-resolve"),
              !fields[1].isEmpty else { throw Self.invalid(line, L10n.text("分流规则格式无效")) }
        guard let policy = Policy(rawValue: fields[2].uppercased()) else {
            warn(L10n.text("第 {0} 行的分流策略已保留，当前版本不执行", line))
            return nil
        }
        let value = fields[1].lowercased()
        switch kind {
        case .domain, .suffix:
            guard Self.isHostname(value, allowEdgeHyphens: true) else { throw Self.invalid(line, L10n.text("域名格式无效")) }
        case .keyword:
            break
        case .ipv4, .ipv6:
            _ = try Self.cidr(value, at: line)
        case .geoIP:
            guard value == "cn" else {
                warn(L10n.text("第 {0} 行只支持 GEOIP,CN", line))
                return nil
            }
        case .port:
            guard Rule.ports(value) != nil else { throw Self.invalid(line, L10n.text("目标端口或范围无效")) }
        }
        return Rule(kind: kind, value: value, policy: policy, noResolve: fields.count == 4, lineNumber: line)
    }

    private mutating func warn(_ message: String) {
        if !warnings.contains(message) { warnings.append(message) }
    }

    private static func values(_ line: String) -> [String] {
        line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func assignment(_ line: String, at number: Int) throws -> (String, String) {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw invalid(number, L10n.text("设置需要键和值"))
        }
        return (parts[0].lowercased(), parts[1])
    }

    private static func flag(_ value: String, at line: Int) throws -> Bool {
        switch value.lowercased() {
        case "true": true
        case "false": false
        default: throw invalid(line, L10n.text("设置需要 true 或 false"))
        }
    }

    private static func resolver(_ value: String, at line: Int) throws -> String {
        if value.lowercased() == "system" { return "system" }
        if IPv4Address(value) != nil || IPv6Address(value) != nil { return value }
        guard let url = URLComponents(string: value), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, (url.port ?? 443) > 0, (url.port ?? 443) <= 65535 else {
            throw invalid(line, L10n.text("主 DNS 需要是 system、IP 地址或 HTTPS DNS 地址"))
        }
        return value
    }

    private static func cidr(_ value: String, at line: Int) throws -> String {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), prefix >= 0,
              (IPv4Address(String(parts[0])) != nil && prefix <= 32 ||
               IPv6Address(String(parts[0])) != nil && prefix <= 128) else {
            throw invalid(line, L10n.text("CIDR 地址格式无效"))
        }
        return value
    }

    private static func isHostname(_ value: String, allowEdgeHyphens: Bool = false) -> Bool {
        value.utf8.count <= 253 && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            (1...63).contains($0.utf8.count) && (allowEdgeHyphens || ($0.first != "-" && $0.last != "-")) &&
            $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        } && !value.isEmpty
    }

    private static func invalid(_ line: Int, _ message: String) -> BywayError {
        .message(L10n.text("第 {0} 行：{1}", line, message))
    }
}
