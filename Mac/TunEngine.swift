import Foundation
import NetworkExtension

/// 全流量接管：App 请一次管理员授权启动特权内核进程，由它用原生 TUN 转发全部流量。
@MainActor
final class TunEngine: MacProxyEngine {
    /// launchd job 名，用来在重复启动前先摘掉上一次的 job。
    private static let launchLabel = "cn.splaz.byway.tun-helper"
    private(set) var status: NEVPNStatus = .invalid
    private var heartbeat: Task<Void, Never>?
    private var isStarting = false
    private let port: UInt16
    private let token: String

    init?() {
        guard let port = MacSettings.tunPort, !MacSettings.tunToken.isEmpty else { return nil }
        self.port = port
        self.token = MacSettings.tunToken
    }

    func start(profile: BywayProfile, store: ProfileStore) async throws {
        // 连点两次「连接」会各拉起一次管理员授权，起两个内核进程。
        guard !isStarting else { throw BywayError.message(L10n.text("全流量内核正在启动")) }
        isStarting = true
        defer { isStarting = false }
        if await ping() {
            status = .connected
            startHeartbeat()
            return
        }
        // 系统代理此时指向 Byway 的混合端口，全流量接管前先恢复，避免双重代理。
        if SystemProxy.current == .byway(port: MacSettings.mixedPort) {
            try? await Task.detached { try SystemProxy.clear() }.value
        }
        try await launch(directory: store.directory)
        for _ in 0..<40 {
            guard !Task.isCancelled else { throw BywayError.message(L10n.text("已取消")) }
            try await Task.sleep(for: .milliseconds(500))
            if await ping() {
                status = .connected
                startHeartbeat()
                return
            }
        }
        throw BywayError.message(L10n.text("全流量内核未启动，请确认管理员授权后重试"))
    }

    func stop() async {
        heartbeat?.cancel()
        heartbeat = nil
        _ = try? await TunControlClient.send(port: port, token: token,
                                             payload: Data(#"{"shutdown":true}"#.utf8), timeout: 6)
        status = .invalid
    }

    func handle(_ data: Data) async -> Data? {
        try? await TunControlClient.send(port: port, token: token, payload: data)
    }

    private func ping() async -> Bool {
        let payload = Data(#"{"ping":true}"#.utf8)
        return (try? await TunControlClient.send(port: port, token: token, payload: payload, timeout: 4)) != nil
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                if await self.ping() {
                    misses = 0
                } else {
                    misses += 1
                    if misses >= 3 {
                        self.status = .invalid
                        return
                    }
                }
            }
        }
    }

    private func launch(directory: URL) async throws {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let log = directory.appending(path: "tun-helper.log")
        // 交给 launchd 托管：`do shell script` 里直接 `&` 起的进程会在 osascript 退出后
        // 不久被回收（实测只活 8–20 秒），心跳还没开始内核就没了，界面却还显示已连接。
        // launchctl submit 的进程挂在 launchd 名下，与 shell 生命周期无关。
        let command = "launchctl remove \(TunEngine.launchLabel) > /dev/null 2>&1; "
            + "launchctl submit -l \(TunEngine.launchLabel) -o /dev/null -e \(TunEngine.shellQuoted(log.path)) -- "
            + "\(TunEngine.shellQuoted(executable.path)) --tun-helper \(TunEngine.shellQuoted(directory.path)) "
            + "\(port) \(TunEngine.shellQuoted(token))"
        // do shell script 的字符串是 AppleScript 字面量，只认双引号；
        // 拿 shell 的单引号去拼会报 -2741 syntax error。
        let script = "do shell script \(TunEngine.appleScriptQuoted(command)) with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        // 授权对话框会阻塞当前线程，放到后台等待。
        try await Task.detached {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw BywayError.message(message.isEmpty ? L10n.text("管理员授权已取消") : message)
            }
        }.value
    }

    /// shell 层的单引号：路径里的空格和引号都按 POSIX shell 规则转义。
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript 字面量：用双引号包裹，反斜杠和双引号都要转义，
    /// 否则 AppleScript 会在自己的解析阶段就失败（-2741）。
    private static func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
