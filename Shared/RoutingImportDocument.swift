import Foundation
#if canImport(Yams)
import Yams
#endif

struct RoutingImportDocument {
    let parsed: ShadowrocketConfiguration
    var warnings: [String] = []

    static func isClash(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let header = line.trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{feff}"]))
            return header.hasPrefix("rules:") || header.hasPrefix("Rules:")
        }
    }

    init(_ text: String) throws {
        guard Self.isClash(text) else {
            parsed = try ShadowrocketConfiguration(text)
            return
        }
        guard text.utf8.count <= ShadowrocketConfiguration.maxBytes else {
            throw BywayError.message(L10n.text("分流配置不能超过 1 MB"))
        }
        #if canImport(Yams)
        let converted = try Self.clash(text)
        parsed = try ShadowrocketConfiguration(converted.text)
        warnings = converted.warnings
        #else
        throw BywayError.message(L10n.text("此构建缺少 Clash 配置解析器"))
        #endif
    }

    #if canImport(Yams)
    private static func clash(_ input: String) throws -> (text: String, warnings: [String]) {
        let root: [String: Any]
        do {
            guard let decoded = try Yams.load(yaml: input) as? [String: Any] else {
                throw BywayError.message(L10n.text("Clash 配置需要包含规则"))
            }
            root = decoded
        } catch {
            throw BywayError.message(L10n.text("无法解析 Clash YAML"))
        }
        let mode = root["mode"] as? String ?? "rule"
        guard mode.lowercased() == "rule", let raw = (root["rules"] ?? root["Rules"]) as? [String], !raw.isEmpty else {
            throw BywayError.message(L10n.text("请导入包含 rules 的 Clash 规则模式配置"))
        }
        for providers in ["proxy-providers", "rule-providers"] {
            if let value = root[providers], !(value is NSNull), (value as? [String: Any])?.isEmpty != true {
                throw BywayError.message(L10n.text("此 Clash 配置依赖 {0}，当前无法保留其更新行为", providers))
            }
        }
        let proxyEntries = (root["proxies"] ?? root["Proxy"]) as? [[String: Any]] ?? []
        let proxyNames = Set(proxyEntries.compactMap { $0["name"] as? String })
        var groups: [String: String] = [:]
        for group in (root["proxy-groups"] ?? root["Proxy Group"]) as? [[String: Any]] ?? [] {
            guard let name = group["name"] as? String, group["type"] as? String == "select",
                  let first = (group["proxies"] as? [String])?.first,
                  !proxyNames.contains(name), groups[name] == nil else {
                throw BywayError.message(L10n.text("Clash 导入支持带有成员的 select 手选策略组"))
            }
            groups[name] = first
        }
        var warnings = [L10n.text("Clash 的代理规则使用 Byway 当前节点。手选策略组使用配置中的第一个成员。")]
        func policy(_ initial: String) throws -> String {
            var target = initial
            var seen = Set<String>()
            while let selected = groups[target] {
                guard seen.insert(target).inserted else { throw BywayError.message(L10n.text("Clash 策略组引用成环")) }
                target = selected
            }
            switch target {
            case "DIRECT", "REJECT": return target
            case "REJECT-DROP":
                if !warnings.contains(L10n.text("REJECT-DROP 使用 Byway 的拒绝行为。")) {
                    warnings.append(L10n.text("REJECT-DROP 使用 Byway 的拒绝行为。"))
                }
                return "REJECT"
            case "PROXY": return "PROXY"
            default:
                guard proxyNames.contains(target) else { throw BywayError.message(L10n.text("Clash 规则引用了未知出口")) }
                return "PROXY"
            }
        }

        var general = ["[General]"]
        if let ipv6 = root["ipv6"] as? Bool { general.append("ipv6 = \(ipv6)") }
        if let dns = root["dns"] as? [String: Any], dns["enable"] as? Bool != false {
            if let first = (dns["nameserver"] as? [String])?.first, first.hasPrefix("https://") || first == "system" {
                general.append("dns-server = " + first)
            }
            warnings.append(L10n.text("Clash 的 DNS 优先读取首个 HTTPS DNS，其他 DNS 策略使用 Byway 设置。"))
        }
        var hosts = ["[Host]"]
        if let entries = root["hosts"] as? [String: Any] {
            for name in entries.keys.sorted() {
                if let addresses = entries[name] as? [String], !addresses.isEmpty {
                    hosts.append(name + " = " + addresses.joined(separator: ","))
                } else if let address = entries[name] as? String {
                    hosts.append(name + " = " + address)
                }
            }
        }

        let supported = Set(ShadowrocketConfiguration.Rule.Kind.allCases.map(\.rawValue))
        var rules = ["[Rule]"]
        for (index, line) in raw.enumerated() {
            guard !line.contains(where: \.isNewline) else { throw BywayError.message(L10n.text("Clash 规则不能包含换行")) }
            var fields = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let kind = fields[0].uppercased()
            if kind == "MATCH" || kind == "FINAL" {
                guard fields.count == 2, index == raw.count - 1 else { throw BywayError.message(L10n.text("Clash MATCH 必须是最后一条规则")) }
                rules.append("FINAL," + (try policy(fields[1])))
                continue
            }
            guard supported.contains(kind), (3...4).contains(fields.count),
                  kind != "GEOIP" || fields[1].uppercased() == "CN" else {
                throw BywayError.message(L10n.text("Clash 第 {0} 条规则暂不支持", index + 1))
            }
            fields[0] = kind
            fields[2] = try policy(fields[2])
            rules.append(fields.joined(separator: ","))
        }
        if rules.last?.hasPrefix("FINAL,") != true { rules.append("FINAL,DIRECT") }
        return ((general + hosts + rules).joined(separator: "\n"), warnings)
    }
    #endif
}
