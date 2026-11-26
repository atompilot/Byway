import Foundation
import SystemConfiguration

/// macOS 系统代理接管。写入前记录原有代理，关闭时恢复正常，避免覆盖用户已有的代理链路。
enum SystemProxy {
    enum Mode: Equatable {
        case off
        case byway(port: Int)
        case other
    }

    private struct Entry: Codable {
        var enabled: Bool
        var host: String
        var port: Int

        /// 配置里存在主机地址（哪怕开关是关的）。
        /// 这种“配好了但没启用”的代理同样属于用户资产，恢复时必须原样写回。
        var configured: Bool { !host.isEmpty }
    }

    private struct Snapshot: Codable {
        var service: String
        var http: Entry
        var https: Entry
        var socks: Entry
        /// 接管前 WPAD（自动代理发现）是否开着。
        var autoDiscovery: Bool
        /// 接管前显式指定的 PAC 地址，空串表示原本没有。
        var autoProxyURL: String

        init(service: String, http: Entry, https: Entry, socks: Entry,
             autoDiscovery: Bool, autoProxyURL: String) {
            self.service = service
            self.http = http
            self.https = https
            self.socks = socks
            self.autoDiscovery = autoDiscovery
            self.autoProxyURL = autoProxyURL
        }

        /// 旧版本快照只有四个字段。缺 autoDiscovery / autoProxyURL 时按“原本没开”处理，
        /// 保证升级后仍然能恢复，而不是因为解码失败丢掉快照、把残留永久留在系统里。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            service = try container.decode(String.self, forKey: .service)
            http = try container.decode(Entry.self, forKey: .http)
            https = try container.decode(Entry.self, forKey: .https)
            socks = try container.decode(Entry.self, forKey: .socks)
            autoDiscovery = try container.decodeIfPresent(Bool.self, forKey: .autoDiscovery) ?? false
            autoProxyURL = try container.decodeIfPresent(String.self, forKey: .autoProxyURL) ?? ""
        }

        enum CodingKeys: String, CodingKey {
            case service, http, https, socks, autoDiscovery, autoProxyURL
        }
    }

    private struct ProxyState {
        var http: Entry
        var https: Entry
        var socks: Entry
        var autoDiscovery: Bool
        var autoProxyURL: String
    }

    private static let snapshotFilename = "proxy-snapshot.json"

    /// 只有三条通道全部落在本机回环上，才算 Byway 自己接管；
    /// 混合配置一律视为“别人的代理”，不去覆盖也不去清理。
    static var current: Mode {
        let proxies = dynamicProxies
        let active = [proxies.http, proxies.https, proxies.socks].filter { $0.enabled && !$0.host.isEmpty }
        guard !active.isEmpty else { return .off }
        guard active.allSatisfy({ isLoopback($0.host) }) else { return .other }
        return .byway(port: active[0].port)
    }

    /// 把当前代理全部（HTTP、HTTPS、SOCKS）指向 Byway 的混合端口，并关掉 WPAD。
    static func apply(port: Int) throws {
        let service = try primaryService()
        if loadSnapshot() == nil {
            let state = proxyState(for: service)
            save(Snapshot(service: service,
                          http: state.http, https: state.https, socks: state.socks,
                          autoDiscovery: state.autoDiscovery, autoProxyURL: state.autoProxyURL))
        }
        var commands = [
            "networksetup -setwebproxy \(quoted(service)) 127.0.0.1 \(port)",
            "networksetup -setsecurewebproxy \(quoted(service)) 127.0.0.1 \(port)",
            "networksetup -setsocksfirewallproxy \(quoted(service)) 127.0.0.1 \(port)"
        ]
        // TUN 接管后系统 DNS 指向隧道地址，WPAD 探测会变成无应答黑洞：
        // CFNetwork 每次建连前都要去取 wpad.dat，等超时期间浏览器表现就是“没有网络”，
        // 而 curl / ping 不读系统代理，看起来一切正常——最难排查的那类断网。
        commands.append("networksetup -setproxyautodiscovery \(quoted(service)) off")
        commands.append("networksetup -setautoproxystate \(quoted(service)) off")
        try privileged(commands)
    }

    /// 恢复接管前的代理配置；没有记录时关闭所有代理。
    static func clear() throws {
        let snapshot = loadSnapshot()
        let service = (try? primaryService()) ?? snapshot?.service
        guard let service else { return }
        var commands: [String] = []
        if let snapshot {
            commands.append(contentsOf: restore(snapshot.http, kind: "webproxy", stateKind: "webproxystate", service: service))
            commands.append(contentsOf: restore(snapshot.https, kind: "securewebproxy", stateKind: "securewebproxystate", service: service))
            commands.append(contentsOf: restore(snapshot.socks, kind: "socksfirewallproxy", stateKind: "socksfirewallproxystate", service: service))
            commands.append(contentsOf: restoreAutomatic(snapshot, service: service))
        } else {
            commands.append(contentsOf: disable(service))
        }
        try privileged(commands)
        if snapshot != nil { save(nil) }
    }

    /// 启动自检：清理“开关已关闭、但 host 仍指向本机回环”的残留代理。
    ///
    /// 这类脏值来自旧版本只执行 `-set...state off`（不清 host/port），
    /// 或者本地代理换了端口、旧端口已经没人监听的场景。平时无害，
    /// 但用户或任何工具一旦把开关打开，全部流量立刻指向空端口——整机断网。
    /// 只清理回环地址，避免误删用户自己配置的公司代理。
    /// 返回实际清理的通道数。
    @discardableResult
    static func repairStale() throws -> Int {
        guard let service = try? primaryService() else { return 0 }
        let state = proxyState(for: service)
        let channels: [(kind: String, stateKind: String, entry: Entry)] = [
            ("webproxy", "webproxystate", state.http),
            ("securewebproxy", "securewebproxystate", state.https),
            ("socksfirewallproxy", "socksfirewallproxystate", state.socks)
        ]
        let stale = channels.filter { !$0.entry.enabled && isLoopback($0.entry.host) }
        guard !stale.isEmpty else { return 0 }
        var commands: [String] = []
        for channel in stale {
            commands.append(contentsOf: clearing(kind: channel.kind, stateKind: channel.stateKind, service: service))
        }
        try privileged(commands)
        return stale.count
    }

    private static func restore(_ entry: Entry, kind: String, stateKind: String, service: String) -> [String] {
        guard entry.configured else {
            return clearing(kind: kind, stateKind: stateKind, service: service)
        }
        // `-set<kind>` 会顺带打开开关，因此“原本配了但没启用”的代理要再补一条 state off，
        // 才能既保留用户的地址、又不把一条本该关闭的代理悄悄打开。
        let assign = "networksetup -set\(kind) \(quoted(service)) \(quoted(entry.host)) \(entry.port)"
        return entry.enabled ? [assign] : [assign, "networksetup -set\(stateKind) \(quoted(service)) off"]
    }

    private static func restoreAutomatic(_ snapshot: Snapshot, service: String) -> [String] {
        var commands = ["networksetup -setproxyautodiscovery \(quoted(service)) \(snapshot.autoDiscovery ? "on" : "off")"]
        if snapshot.autoProxyURL.isEmpty {
            commands.append("networksetup -setautoproxystate \(quoted(service)) off")
        } else {
            commands.append("networksetup -setautoproxyurl \(quoted(service)) \(quoted(snapshot.autoProxyURL))")
        }
        return commands
    }

    /// 清空一条代理通道的 host 与 port，再把开关关掉。
    /// `-set<kind> '<服务>' '' 0` 会顺带把开关打开，所以必须紧跟一条 state off。
    /// 两条用 `;` 连接，前者失败也不影响后者把开关关掉。
    private static func clearing(kind: String, stateKind: String, service: String) -> [String] {
        ["networksetup -set\(kind) \(quoted(service)) '' 0; networksetup -set\(stateKind) \(quoted(service)) off"]
    }

    private static func disable(_ service: String) -> [String] {
        var commands: [String] = []
        for channel in [("webproxy", "webproxystate"),
                        ("securewebproxy", "securewebproxystate"),
                        ("socksfirewallproxy", "socksfirewallproxystate")] {
            commands.append(contentsOf: clearing(kind: channel.0, stateKind: channel.1, service: service))
        }
        commands.append("networksetup -setproxyautodiscovery \(quoted(service)) off")
        commands.append("networksetup -setautoproxystate \(quoted(service)) off")
        return commands
    }

    private static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "::1", "localhost"].contains(host.lowercased())
    }

    /// 完整的、以 preferences.plist 为准的配置。
    ///
    /// 不能用 `SCDynamicStoreCopyProxies` 做这件事：开关关闭时它不返回 HTTPProxy / HTTPPort，
    /// 读出来永远是一对空值。用它做快照，用户“配好但暂时关着”的代理会被记成空，
    /// 退出时直接丢掉；用它做自检，也永远发现不了“开关关着、host 还指着回环”的残留。
    private static func proxyState(for service: String) -> ProxyState {
        func entry(_ command: String) -> Entry {
            let output = run("/usr/sbin/networksetup", ["-get\(command)", service])
            var enabled = false
            var host = ""
            var port = 0
            for line in output.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("Enabled:") {
                    enabled = text.lowercased().contains("yes")
                } else if text.hasPrefix("Server:") {
                    host = String(text.dropFirst("Server:".count)).trimmingCharacters(in: .whitespaces)
                } else if text.hasPrefix("Port:") {
                    port = Int(String(text.dropFirst("Port:".count)).trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            return Entry(enabled: enabled, host: host, port: port)
        }

        let discovery = run("/usr/sbin/networksetup", ["-getproxyautodiscovery", service])
        var autoProxyURL = ""
        for line in run("/usr/sbin/networksetup", ["-getautoproxyurl", service]).split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("URL:") else { continue }
            let value = String(text.dropFirst("URL:".count)).trimmingCharacters(in: .whitespaces)
            if value != "(null)" { autoProxyURL = value }
        }
        return ProxyState(http: entry("webproxy"),
                          https: entry("securewebproxy"),
                          socks: entry("socksfirewallproxy"),
                          autoDiscovery: discovery.lowercased().contains("on"),
                          autoProxyURL: autoProxyURL)
    }

    /// 只读当前生效值的轻量视图，用于 UI 上判断“现在是谁在接管”。
    private static var dynamicProxies: ProxyState {
        let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:]
        func entry(_ enable: String, _ host: String, _ port: String) -> Entry {
            Entry(enabled: (proxies[enable] as? Int ?? 0) == 1,
                  host: proxies[host] as? String ?? "",
                  port: proxies[port] as? Int ?? 0)
        }
        return ProxyState(
            http: entry(kSCPropNetProxiesHTTPEnable as String, kSCPropNetProxiesHTTPProxy as String,
                        kSCPropNetProxiesHTTPPort as String),
            https: entry(kSCPropNetProxiesHTTPSEnable as String, kSCPropNetProxiesHTTPSProxy as String,
                         kSCPropNetProxiesHTTPSPort as String),
            socks: entry(kSCPropNetProxiesSOCKSEnable as String, kSCPropNetProxiesSOCKSProxy as String,
                         kSCPropNetProxiesSOCKSPort as String),
            autoDiscovery: (proxies[kSCPropNetProxiesProxyAutoDiscoveryEnable as String] as? Int ?? 0) == 1,
            autoProxyURL: proxies[kSCPropNetProxiesProxyAutoConfigURLString as String] as? String ?? ""
        )
    }

    static func primaryService() throws -> String {
        let list = networkServices()
        if let interface = primaryInterface(), let match = list.first(where: { $0.device == interface }) {
            return match.name
        }
        if let wifi = list.first(where: { $0.name == "Wi-Fi" || $0.device == "en0" }) {
            return wifi.name
        }
        if let first = list.first { return first.name }
        throw LANFailure(503, L10n.text("找不到当前使用的网络服务"))
    }

    private static func networkServices() -> [(name: String, device: String?)] {
        guard let preferences = SCPreferencesCreate(nil, "Byway" as CFString, nil),
              let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else { return [] }
        return services.compactMap { service in
            guard let name = SCNetworkServiceGetName(service) as String? else { return nil }
            let device = SCNetworkServiceGetInterface(service).flatMap {
                SCNetworkInterfaceGetBSDName($0) as String?
            }
            return (name, device)
        }
    }

    private static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Byway" as CFString, nil, nil),
              let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else {
            return nil
        }
        return ipv4["PrimaryInterface"] as? String
    }

    // MARK: - 快照持久化

    /// 快照必须落在 GUI 与 root 助手都能读到的同一份文件上。
    /// 早期版本放在 `UserDefaults.standard` 里，而 GUI 跑在登录用户域、`--tun-helper` 跑在 root 域，
    /// 助手恢复时永远读不到那份快照，于是只能退化成“完全关闭”，把原来的设置丢掉。
    private static var snapshotDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["BYWAY_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // 优先落在真实登录用户的家目录：GUI 与 root 助手据此指向同一份文件。
        if let home = consoleUserHome() {
            return home.appendingPathComponent("Library/Application Support/Byway", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Byway", isDirectory: true)
    }

    private static var snapshotURL: URL {
        snapshotDirectory.appendingPathComponent(snapshotFilename)
    }

    private static func loadSnapshot() -> Snapshot? {
        for url in candidateSnapshotURLs() {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) { return snapshot }
        }
        return nil
    }

    /// 读取时把当前进程自己的目录也纳入候选，避免早期版本留下的快照读不到。
    private static func candidateSnapshotURLs() -> [URL] {
        var urls = [snapshotURL]
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Byway/\(snapshotFilename)")
        if !urls.contains(where: { $0.path == fallback.path }) { urls.append(fallback) }
        return urls
    }

    /// root 助手运行时，取真实登录用户的家目录，而不是 /var/root。
    private static func consoleUserHome() -> URL? {
        guard let raw = SCDynamicStoreCopyConsoleUser(nil, nil, nil) else { return nil }
        let name = raw as String
        guard !name.isEmpty, name != "loginwindow" else { return nil }
        return URL(fileURLWithPath: "/Users/\(name)", isDirectory: true)
    }

    private static func save(_ snapshot: Snapshot?) {
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else {
            for url in candidateSnapshotURLs() { try? FileManager.default.removeItem(at: url) }
            return
        }
        let url = snapshotURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // 落盘失败不能静默：没有快照，退出时就无法还原用户原来的代理。
            NSLog(L10n.text("Byway: 代理快照写入失败 {0}: {1}", url.path, error.localizedDescription))
        }
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func privileged(_ commands: [String]) throws {
        guard !commands.isEmpty else { return }
        // do shell script 对底层 AppleScript 参数只认双引号。
        // 直接把 shell 的单引号拼进去会在 AppleScript 解析阶段报 -2741。
        let script = "do shell script \(appleScriptQuoted(commands.joined(separator: " && "))) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw LANFailure(503, message.isEmpty ? L10n.text("系统代理未更新") : message)
        }
    }

    /// shell 单引号转义，屏蔽 networksetup 的服务名。
    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript 字符串用双引号包裹，内部的双引号和反斜杠都要转义。
    private static func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
