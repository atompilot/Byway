import Foundation

/// 在本机验证 macOS 版代理内核：导入 Shadowrocket 导出，启动混合端口，运行时用 curl 检查出口。
@main
struct MacEngineFixture {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            print("usage: mac-engine-fixture <shadowrocket-export.json> <seconds> [port] [mixed|tun]")
            exit(2)
        }
        let seconds = Double(arguments[2]) ?? 20
        let port = arguments.count > 3 ? (Int(arguments[3]) ?? 7890) : 7890
        let inbound: EngineInbound = arguments.count > 4 && arguments[4] == "tun" ? .tun : .mixed(port: port)
        do {
            let text = try String(contentsOfFile: arguments[1], encoding: .utf8)
            let imported = try NodeImport(text)
            var profile = BywayProfile()
            profile.nodes = imported.nodes
            profile.selectedID = imported.nodes.first?.id
            let store = try ProfileStore.open()
            try store.save(profile)
            if let id = profile.selectedID { try store.saveActiveNode(id) }
            print("nodes=\(profile.nodes.count) selected=\(profile.nodes.first?.name ?? "-") inbound=\(inbound) port=\(port)")

            let runtime = TunnelRuntime()
            try await runtime.start(profile: profile, store: store, provider: nil,
                                    inbound: inbound,
                                    terminate: { error in
                                        print("engine=terminated \(error?.localizedDescription ?? "-")")
                                    })
            print("engine=ready")
            try await Task.sleep(for: .seconds(seconds))
            await runtime.stop()
            print("engine=stopped")
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }
}
