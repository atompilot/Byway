import Foundation

struct PrivateNetworkInput: Codable, Equatable, Sendable {
    enum Provider: String, Codable, CaseIterable, Sendable {
        case headscale, tailscale
        var title: String { self == .headscale ? L10n.text("自托管 Headscale") : L10n.text("Tailscale 账号") }
    }

    enum RelayMode: String, Codable, CaseIterable, Sendable {
        case tailscaleDefault, strict

        var title: String {
            switch self {
            case .tailscaleDefault: L10n.text("跟随 Tailscale 配置")
            case .strict: L10n.text("严格匹配自定义中继")
            }
        }
    }

    var provider: Provider
    var controlURL: String
    var relayHosts: [String]
    var deviceName: String
    var relayMode: RelayMode

    init(provider: Provider, controlURL: String, relayHosts: [String], deviceName: String,
         relayMode: RelayMode = .strict) {
        self.provider = provider
        self.controlURL = controlURL
        self.relayHosts = relayHosts
        self.deviceName = deviceName
        self.relayMode = relayMode
    }

    private enum CodingKeys: String, CodingKey { case provider, controlURL, relayHosts, deviceName, relayMode }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(provider: try values.decode(Provider.self, forKey: .provider),
                  controlURL: try values.decode(String.self, forKey: .controlURL),
                  relayHosts: try values.decode([String].self, forKey: .relayHosts),
                  deviceName: try values.decode(String.self, forKey: .deviceName),
                  relayMode: try values.decodeIfPresent(RelayMode.self, forKey: .relayMode) ?? .strict)
    }

    func validated() throws -> Self {
        var result = self
        if provider == .tailscale {
            result.controlURL = "https://controlplane.tailscale.com"
        } else {
            guard let url = URLComponents(string: controlURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme?.lowercased() == "https", let host = url.host, Self.validHost(host),
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/", let normalized = url.url else {
                throw LANFailure(422, L10n.text("请填写有效的 HTTPS 协调服务器地址"))
            }
            result.controlURL = normalized.absoluteString.hasSuffix("/") ? String(normalized.absoluteString.dropLast()) : normalized.absoluteString
        }
        switch relayMode {
        case .tailscaleDefault:
            guard provider == .tailscale, relayHosts.isEmpty else {
                throw LANFailure(422, L10n.text("跟随 Tailscale 配置仅适用于 Tailscale 账号，请留空中继域名"))
            }
        case .strict:
            result.relayHosts = Array(Set(relayHosts.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
            })).sorted()
            guard (1...16).contains(result.relayHosts.count), result.relayHosts.allSatisfy(Self.validHost) else {
                throw LANFailure(422, L10n.text("请填写 1 到 16 个有效的中继域名"))
            }
        }
        result.deviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard result.deviceName.isEmpty || result.deviceName.range(
            of: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression
        ) != nil else {
            throw LANFailure(422, L10n.text("设备名请使用英文字母、数字或短横线"))
        }
        return result
    }

    private static func validHost(_ value: String) -> Bool {
        value.count <= 253 && value.range(
            of: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

struct PrivateNetworkSettings: Codable, Equatable, Sendable {
    let identity: UUID
    var input: PrivateNetworkInput
    var enabled: Bool
    var lastAddresses: [String] = []
    var lastDNSSuffix: String?

    static let tag = "byway-private"
    static let dnsTag = "byway-private-dns"
    static let addressRanges = [("100.64.0.0/10", 10), ("fd7a:115c:a1e0::/48", 48)]

    static func excludesPrivateAddress(_ route: String) -> Bool {
        let fields = route.split(separator: "/")
        guard fields.count == 2, let length = Int(fields[1]) else { return false }
        return addressRanges.contains { range, rangeLength in
            length >= rangeLength && ShadowrocketConfiguration.matches(String(fields[0]), cidr: range)
        }
    }

    func update(_ input: PrivateNetworkInput) throws -> Self {
        let validated = try input.validated()
        guard validated.provider == self.input.provider, validated.controlURL == self.input.controlURL else {
            throw LANFailure(409, L10n.text("请先退出当前私网，再更换协调服务器"))
        }
        var next = self
        next.input = validated
        return next
    }

    func endpoint(in root: URL) -> [String: Any] {
        var endpoint: [String: Any] = [
            "type": "tailscale", "tag": Self.tag, "control_url": input.controlURL,
            "state_directory": root.appending(path: "private-network/\(identity.uuidString)").path,
            "domain_resolver": "bootstrap"
        ]
        switch input.relayMode {
        case .tailscaleDefault: endpoint["byway_follow_control_relays"] = true
        case .strict: endpoint["byway_relays"] = input.relayHosts
        }
        if !input.deviceName.isEmpty { endpoint["hostname"] = input.deviceName }
        return endpoint
    }
}

struct PrivateNetworkSettingsView: Codable, Equatable, Sendable {
    let configuration: PrivateNetworkInput?
    let enabled: Bool
    let runtime: PrivateNetworkRuntime?

    init(_ settings: PrivateNetworkSettings?, runtime: PrivateNetworkRuntime? = nil) {
        configuration = settings?.input
        enabled = settings?.enabled == true
        self.runtime = runtime
    }

    var state: String {
        if configuration == nil { return L10n.text("未配置") }
        if !enabled { return L10n.text("已暂停") }
        guard let runtime else { return L10n.text("等待 VPN") }
        switch runtime.state {
        case "NeedsLogin": return L10n.text("等待登录")
        case "NeedsMachineAuth": return L10n.text("等待管理员授权")
        case "RelayMismatch": return L10n.text("中继清单不符")
        case "Running" where runtime.relays?.verified == true: return L10n.text("已连接")
        case "Stopped": return L10n.text("已断开")
        default: return L10n.text("正在连接")
        }
    }
}

struct PrivateNetworkRuntime: Codable, Equatable, Sendable {
    struct RelayAudit: Codable, Equatable, Sendable {
        let hosts: [String]
        let verified: Bool
    }

    var state: String
    let network: String?
    let dnsSuffix: String?
    let addresses: [String]
    let peers: [PrivateNetworkPeer]
    let relays: RelayAudit?
    var authURL: String?
}

struct PrivateNetworkPeer: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let dnsName: String
    let os: String
    let addresses: [String]
    let online: Bool
}

struct PrivateNetworkProbe: Codable, Equatable, Sendable {
    let path: String
    let region: String
    let latencyMs: Double
    let observedAt: String

    var summary: String {
        let kind: String
        switch path {
        case "direct": kind = L10n.text("直连")
        case "derp": kind = region.isEmpty ? L10n.text("中继") : L10n.text("中继 {0}", region)
        case "peerRelay": kind = L10n.text("设备中继")
        default: kind = L10n.text("路径未知")
        }
        return "\(kind) · \(Int(latencyMs.rounded())) ms"
    }
}

enum PrivateNetworkChange: Sendable {
    case configure(PrivateNetworkInput)
    case enable(Bool)
    case leave

    func applying(to current: PrivateNetworkSettings?) throws -> PrivateNetworkSettings? {
        switch self {
        case .configure(let input):
            if let current { return try current.update(input) }
            return PrivateNetworkSettings(identity: UUID(), input: try input.validated(), enabled: false)
        case .enable(let enabled):
            guard var current else { throw LANFailure(409, L10n.text("请先配置私网")) }
            current.enabled = enabled
            return current
        case .leave:
            return nil
        }
    }
}

struct PrivateNetworkReceipt: Sendable {
    let status: PrivateNetworkSettingsView
    var afterReply: (@Sendable () -> Void)?
}

struct PrivateNetworkLocalRequest: Codable, Sendable {
    enum Action: String, Codable, Sendable { case status, key }
    let privateNetwork: Action
    var key: String?
}
