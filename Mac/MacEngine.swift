import Foundation
import NetworkExtension

/// Mac 版两种接管方式共用的内核接口。
@MainActor
protocol MacProxyEngine: AnyObject {
    var status: NEVPNStatus { get }
    func start(profile: BywayProfile, store: ProfileStore) async throws
    func stop() async
    func handle(_ data: Data) async -> Data?
}

/// Mac 版接管方式。系统代理与仅监听使用进程内混合端口，全流量使用特权内核进程。
/// 枚举顺序即菜单顺序，按对系统的影响从高到低排列。
enum MacTakeover: String, CaseIterable, Identifiable {
    case tun
    case systemProxy
    case listenOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .tun: L10n.text("全流量")
        case .systemProxy: L10n.text("系统代理")
        case .listenOnly: L10n.text("仅监听")
        }
    }

    var englishTitle: String {
        switch self {
        case .tun: "TUN"
        case .systemProxy: "System Proxy"
        case .listenOnly: "Listen Only"
        }
    }

    var menuTitle: String { "\(title) · \(englishTitle)" }

    /// 影响范围：谁会被接管、要不要管理员授权。
    var detail: String {
        switch self {
        case .tun: L10n.text("接管默认路由，所有应用、终端和系统服务的流量都进节点；需要一次管理员授权。")
        case .systemProxy: L10n.text("只写入系统代理设置，遵循系统代理的应用进节点，终端等不读代理的程序直连；需要一次管理员授权。")
        case .listenOnly: L10n.text("只在 127.0.0.1 上监听混合端口，不改任何系统设置，由应用自己指定代理。")
        }
    }

    /// 一行版本，给菜单和选择器做提示。
    var scopeSummary: String {
        switch self {
        case .tun: L10n.text("全部流量")
        case .systemProxy: L10n.text("读系统代理的 App")
        case .listenOnly: L10n.text("不改系统设置")
        }
    }
}

/// 进程内运行代理内核：配置使用本机混合端口，系统代理指向该端口。
@MainActor
final class MacEngine: MacProxyEngine {
    private(set) var runtime: TunnelRuntime?
    private(set) var failure: String?

    var status: NEVPNStatus { runtime == nil ? .invalid : .connected }
    var port: Int { MacSettings.mixedPort }

    func start(profile: BywayProfile, store: ProfileStore) async throws {
        guard runtime == nil else { return }
        failure = nil
        let runtime = TunnelRuntime()
        do {
            try await runtime.start(profile: profile, store: store, provider: nil,
                                    inbound: .mixed(port: MacSettings.mixedPort),
                                    terminate: { [weak self] error in
                                        Task { @MainActor [weak self] in
                                            self?.failure = error?.localizedDescription
                                            await self?.stop()
                                        }
                                    })
        } catch {
            await runtime.stop()
            throw error
        }
        self.runtime = runtime
    }

    func stop() async {
        guard let runtime else { return }
        self.runtime = nil
        await runtime.stop()
    }

    func handle(_ data: Data) async -> Data? {
        guard let runtime else { return nil }
        return await runtime.handleMessage(data)
    }
}

enum MacSettings {
    private static let portKey = "BywayMixedPort"
    private static let takeoverKey = "BywayTakeover"
    private static let tokenKey = "BywayTunToken"

    static var mixedPort: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: portKey)
            return stored > 0 && stored < 65536 ? stored : 7890
        }
        set { UserDefaults.standard.set(newValue, forKey: portKey) }
    }

    static var tunPort: UInt16? { 47890 }

    /// 特权内核进程的访问令牌，与回环端口一起限定本机访问。
    static var tunToken: String {
        if let stored = UserDefaults.standard.string(forKey: tokenKey), stored.count == 32 { return stored }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(token, forKey: tokenKey)
        return token
    }

    static var takeover: MacTakeover {
        get {
            guard let raw = UserDefaults.standard.string(forKey: takeoverKey),
                  let value = MacTakeover(rawValue: raw) else { return .systemProxy }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: takeoverKey) }
    }
}
