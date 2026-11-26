import Darwin
import Foundation

/// 全流量接管期间把系统 DNS 指向虚拟网卡。
///
/// 只靠 tun 的 `hijack-dns` 不够：系统解析器把查询发给局域网网关
/// （192.168.31.1），这条流量走物理网卡、根本不进 tun，所以查询用的是本地 DNS，
/// 境外域名会被污染成错误地址——表现就是「国内能上、国外全挂」。
/// 把 DNS 指到 tun 地址后，查询才真正进内核，交给配置里的加密 DNS 经节点解析。
enum SystemDNS {
    struct Snapshot {
        let service: String
        let servers: [String]
    }

    /// 把当前默认路由所在网络服务的 DNS 换成 `address`，返回原值供恢复。
    static func pointAtTunnel(_ address: String) -> Snapshot? {
        guard let service = primaryService() else { return nil }
        let previous = servers(of: service)
        setServers([address], for: service)
        flushCache()
        return Snapshot(service: service, servers: previous)
    }

    static func restore(_ snapshot: Snapshot?) {
        guard let snapshot else { return }
        setServers(snapshot.servers, for: snapshot.service)
        flushCache()
    }

    /// 启动自愈：系统 DNS 还停在一个本机已经不存在的隧道地址上时，清空让 DHCP 重新下发。
    ///
    /// helper 被强杀（kill -9 / 崩溃 / 断电）时不会走任何退出分支，`restore` 也就不会执行：
    /// DNS 永久停在已经消失的 tun 地址上，每一次域名解析都超时，整机看起来像“彻底没网”，
    /// 而 IP 直连（ping、curl 打 IP）却完全正常——最容易误判成路由或运营商问题。
    /// 返回是否真的修过。
    @discardableResult
    static func repairStalePointer(_ address: String) -> Bool {
        guard let service = primaryService() else { return false }
        guard servers(of: service).contains(address) else { return false }
        // 本机确实持有这个地址（隧道还活着）时不能动，否则会把正在工作的接管拆掉。
        guard !localAddresses().contains(address) else { return false }
        setServers([], for: service)
        flushCache()
        return true
    }

    /// 本机所有接口上当前配置的 IP，用来判断某个地址是不是“已经消失”。
    private static func localAddresses() -> Set<String> {
        var result: Set<String> = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = address.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = family == UInt8(AF_INET)
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.insert(String(cString: host))
        }
        return result
    }

    /// 默认路由所在接口对应的网络服务名，例如 en0 → "Wi-Fi"。
    private static func primaryService() -> String? {
        guard let interface = run("/sbin/route", ["-n", "get", "default"])
            .split(separator: "\n")
            .first(where: { $0.contains("interface:") })?
            .split(separator: ":")
            .last?
            .trimmingCharacters(in: .whitespaces), !interface.isEmpty else { return nil }
        guard let order = run("/usr/sbin/networksetup", ["-listnetworkserviceorder"]) as String? else {
            return nil
        }
        var pending: String?
        for line in order.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            // 服务行是 "(6) Wi-Fi"；硬件行是 "(Hardware Port: …, Device: en0)"。
            // 只有序号为纯数字的那行才是服务名，否则会把硬件行误当成名字。
            if text.hasPrefix("("), let close = text.firstIndex(of: ")"),
               text[text.index(after: text.startIndex)..<close].allSatisfy(\.isNumber) {
                pending = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            } else if text.contains("Device: \(interface)"), let service = pending, !service.isEmpty {
                return service
            }
        }
        return nil
    }

    private static func servers(of service: String) -> [String] {
        let output = run("/usr/sbin/networksetup", ["-getdnsservers", service])
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("There aren") }
    }

    private static func setServers(_ servers: [String], for service: String) {
        let arguments = ["-setdnsservers", service] + (servers.isEmpty ? ["Empty"] : servers)
        _ = run("/usr/sbin/networksetup", arguments)
    }

    private static func flushCache() {
        _ = run("/usr/bin/dscacheutil", ["-flushcache"])
        _ = run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
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
}
