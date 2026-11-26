import Darwin
import Foundation
import NetworkExtension

/// 以 root 运行的内核进程。App 通过一次管理员授权启动它，
/// 由它使用原生 TUN 接管全部流量，并通过本机回环通道接受同一套管理指令。
enum TunHelper {
    /// 与 `BywayProfile.engineConfiguration` 里 tun inbound 的 IPv4 地址保持一致。
    static let tunAddress = "172.28.80.1"

    static var isRequested: Bool { CommandLine.arguments.contains("--tun-helper") }

    static func run() -> Never {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--tun-helper"),
              arguments.count > index + 3,
              let port = UInt16(arguments[index + 2]) else {
            FileHandle.standardError.write(Data("usage: Byway --tun-helper <profileDir> <port> <token>\n".utf8))
            exit(2)
        }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        let token = arguments[index + 3]
        // 同一份配置只允许一个内核进程：重复授权会起第二个 helper，
        // 两个进程抢同一块 TUN 和同一个控制端口时会把转发搅成半通状态。
        switch acquireInstanceLock(directory: directory) {
        case .acquired(let descriptor):
            _ = descriptor   // 故意不关闭，进程结束后由内核释放锁
        case .busy:
            Helper.log("another helper already serves \(directory.path)")
            exit(0)
        case .failed(let reason):
            Helper.log("helper lock unavailable: \(reason)")
            exit(1)
        }
        // 上一次可能是被强杀/崩溃退出的，DNS 还停在已经不存在的 tun 地址上。
        // 先把它清掉，否则接下来所有解析都会超时，用户看到的就是“没网了”。
        if SystemDNS.repairStalePointer(tunAddress) {
            Helper.log("stale dns pointer cleared before engine start")
        }
        let store = ProfileStore(directory: directory)

        let state = HelperState()

        let runtime = TunnelRuntime()
        var profile: BywayProfile
        do {
            profile = try store.read()
            if let active = store.activeNodeID(), profile.nodes.contains(where: { $0.id == active }) {
                profile.selectedID = active
            }
        } catch {
            Helper.log("profile failed: \(error.localizedDescription)")
            state.quit(1)
        }
        guard let server = TunControlServer(port: port, token: token, handle: { payload in
            await state.handle(payload, runtime: runtime)
        }, onEvent: {
            state.touch()
        }) else {
            Helper.log("control socket failed")
            state.quit(1)
        }
        server.start()
        Helper.log("control listening on 127.0.0.1:\(port)")

        for delay in [1, 3, 8, 20] {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                do {
                    let reply = try await TunControlClient.send(port: port, token: token,
                                                                payload: Data(#"{"ping":true}"#.utf8), timeout: 4)
                    Helper.log("self-test@\(delay)s ok: \(reply.count) bytes")
                } catch {
                    Helper.log("self-test@\(delay)s failed: \(error.localizedDescription)")
                }
            }
        }

        Task {
            let began = Date()
            do {
                try await runtime.start(profile: profile, store: store, provider: nil, inbound: .tun,
                                        terminate: { error in
                    Helper.log(error.map { "engine stopped: \($0.localizedDescription)" } ?? "engine stopped: tun closed")
                    state.releaseDNS()
                    state.detachFromLaunchd()
                    state.quit(0)
                })
                Helper.log("engine started in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
                // 系统解析器默认把查询发给网关，那条流量不进 tun，境外域名会被本地 DNS 污染。
                // 指到 tun 地址后，查询才进内核、走加密 DNS 经节点解析。
                let dns = SystemDNS.pointAtTunnel(TunHelper.tunAddress)
                state.adoptDNS(dns)
                Helper.log("system dns -> \(TunHelper.tunAddress) on \(dns?.service ?? "unknown")")
            } catch {
                Helper.log("engine failed: \(error.localizedDescription)")
                state.quit(1)
            }
            state.watchdog {
                Task {
                    state.releaseDNS()
                    state.detachFromLaunchd()
                    await runtime.stop()
                    state.quit(0)
                }
            }
        }

        // 主线程必须保持 run loop 运行：Network.framework 的内部队列要用它，
        // 用 semaphore 阻塞主线程会让控制通道接不接受连接都不再回调。
        RunLoop.main.run()
        state.quit(0)
    }

    /// 用配置目录里的锁文件做单实例约束；文件描述符故意不关闭，进程结束后由内核释放。
    /// 锁文件本身用 0666：内核进程以 root 创建，写成 0644 会让非 root 的排查进程
    /// 连 open 都失败，从而被误判成「已有实例在跑」。
    private enum InstanceLock {
        case acquired(Int32)
        case busy
        case failed(String)
    }

    private static func acquireInstanceLock(directory: URL) -> InstanceLock {
        let path = directory.appending(path: "tun-helper.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o666)
        guard descriptor >= 0 else {
            return .failed(String(cString: strerror(errno)))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            return code == EWOULDBLOCK ? .busy : .failed(String(cString: strerror(code)))
        }
        return .acquired(descriptor)
    }

    /// 记录最后一次收到指令的时间；App 退出或崩溃后由看门狗结束内核，避免 TUN 残留。
    private final class HelperState: @unchecked Sendable {
        private let lock = NSLock()
        private var lastActivity = Date()
        private var finished = false
        private var dns: SystemDNS.Snapshot?

        /// 记录接管前的系统 DNS，退出时原样写回。
        func adoptDNS(_ snapshot: SystemDNS.Snapshot?) {
            lock.lock()
            dns = snapshot
            lock.unlock()
        }

        /// 先归还系统 DNS。`runtime.stop()` 有可能长时间不返回，而 DNS 停在一个
        /// 已经消失的 tun 地址上会让整机解析直接失效，所以这一步必须排在停引擎之前。
        func releaseDNS() {
            lock.lock()
            let snapshot = dns
            dns = nil
            lock.unlock()
            guard let snapshot else { return }
            SystemDNS.restore(snapshot)
            Helper.log("system dns restored on \(snapshot.service)")
        }

        /// 从 launchd 摘掉自己的 job。`launchctl submit` 的 job 在进程退出后会被重新拉起，
        /// 新实例又会把系统 DNS 指回 tun，形成「关了又起」的循环。
        func detachFromLaunchd() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["remove", "cn.splaz.byway.tun-helper"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }

        /// 统一退出入口：先还原系统 DNS，再结束进程。
        func quit(_ code: Int32) -> Never {
            lock.lock()
            let snapshot = dns
            dns = nil
            lock.unlock()
            SystemDNS.restore(snapshot)
            Helper.exit(code)
        }

        func touch() {
            lock.lock()
            lastActivity = Date()
            lock.unlock()
        }

        func finish() {
            lock.lock()
            finished = true
            lock.unlock()
        }

        func handle(_ payload: Data, runtime: TunnelRuntime) async -> Data? {
            if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                // 心跳直接回答，避免内核繁忙时把存活判断拖到超时。
                if object["ping"] as? Bool == true { return Data() }
                if object["shutdown"] as? Bool == true {
                    Helper.log("shutdown requested")
                    releaseDNS()
                    detachFromLaunchd()
                    await runtime.stop()
                    finish()
                    self.quit(0)
                }
            }
            return await runtime.handleMessage(payload)
        }

        func watchdog(_ stop: @escaping @Sendable () -> Void) {
            // 用 Swift 并发计时而不是 main queue 的 DispatchSource：
            // 主线程被 RunLoop.run() 占住时，主队列计时器不保证被唤醒，
            // 内核会在 App 已经退出后继续接管默认路由。
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard let self else { return }
                    self.lock.lock()
                    let idle = Date().timeIntervalSince(self.lastActivity)
                    let stopped = self.finished
                    self.lock.unlock()
                    if stopped || idle > 90 {
                        stop()
                        return
                    }
                }
            }
        }
    }

    /// 统一的内核进程日志出口，子进程的标准错误由 App 重定向到配置目录。
    enum Helper {
        private static let stamp: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withTime, .withFractionalSeconds]
            return formatter
        }()

        static func log(_ message: String) {
            // 带时间戳，排查「上一次会话」和「这一次」混在同一个文件里的情况。
            FileHandle.standardError.write(Data(("\(stamp.string(from: Date())) \(message)\n").utf8))
        }

        /// 退出前给标准错误一点刷盘时间，避免日志丢在进程结束里。
        static func exit(_ code: Int32) -> Never {
            fflush(stderr)
            Darwin.exit(code)
        }
    }
}
