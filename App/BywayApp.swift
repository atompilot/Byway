import SwiftUI

#if os(macOS)
@main
enum BywayMacMain {
    @MainActor static func main() {
        if TunHelper.isRequested { TunHelper.run() }
        #if DEBUG
        if SnapshotHook.renderOffscreenIfRequested() { return }
        #endif
        BywayMacApp.main()
    }
}

struct BywayMacApp: App {
    @StateObject private var controller = VPNController()
    @StateObject private var localControl = LANControl()

    var body: some Scene {
        WindowGroup {
            BywayRootView(controller: controller, localControl: localControl)
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button(L10n.text("连接或断开代理")) { Task { await controller.toggleConnection() } }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Menu(L10n.text("接管方式")) {
                    ForEach(MacTakeover.allCases) { option in
                        Button {
                            Task { await controller.setTakeover(option) }
                        } label: {
                            Text(controller.takeover == option ? "✓ \(option.menuTitle)" : option.menuTitle)
                        }
                        .help(option.detail)
                    }
                }
                Divider()
                Button(L10n.text("设为系统代理")) { Task { await controller.applySystemProxy() } }
                Button(L10n.text("关闭系统代理")) { Task { await controller.clearSystemProxy() } }
                Divider()
                Button(L10n.text("打开管理网页")) { openManagementPage() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }
    }

    private func openManagementPage() {
        guard let address = localControl.address, let url = URL(string: address + "/") else { return }
        NSWorkspace.shared.open(url)
    }
}
#else
@main
struct BywayApp: App {
    @StateObject private var controller = VPNController()
    @StateObject private var localControl = LANControl()

    var body: some Scene {
        WindowGroup {
            BywayRootView(controller: controller, localControl: localControl)
        }
    }
}
#endif

private struct BywayRootView: View {
    @ObservedObject var controller: VPNController
    @ObservedObject var localControl: LANControl
    @Environment(\.scenePhase) private var scenePhase

    private var shouldPoll: Bool { scenePhase == .active && controller.connected }

    #if os(macOS)
    private var snapshotPage: MacPage {
        #if DEBUG
        return SnapshotHook.requestedPage ?? .nodes
        #else
        return .nodes
        #endif
    }

    private var snapshotNodeID: UUID? {
        #if DEBUG
        return SnapshotHook.requestedNodeID
        #else
        return nil
        #endif
    }
    #endif

    var body: some View {
        Group {
            #if os(macOS)
            MacWorkspace(controller: controller, localControl: localControl,
                         initialPage: snapshotPage, initialNodeID: snapshotNodeID)
            #else
            if UIDevice.current.userInterfaceIdiom == .pad {
                PadWorkspace(controller: controller, localControl: localControl)
            } else {
                HomeView(controller: controller, localControl: localControl)
            }
            #endif
        }
        .task { await controller.load() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            localControl.setForeground(phase == .active, vpn: controller)
            if phase == .active { controller.refresh() }
        }
        .onChange(of: controller.canHostLAN) { _, _ in localControl.refresh(vpn: controller) }
        .onChange(of: controller.status) { _, _ in localControl.refresh(vpn: controller) }
        .task(id: shouldPoll) {
            controller.clearTrafficRates()
            if !shouldPoll {
                if !controller.connected { await controller.refreshTraffic() }
                await controller.refreshPrivateNetworkSummary()
                return
            }
            while !Task.isCancelled {
                controller.refresh()
                localControl.refresh(vpn: controller)
                await controller.refreshTraffic()
                await controller.refreshPrivateNetworkSummary()
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
        .alert("Byway", isPresented: Binding(
            get: { controller.message != nil },
            set: { if !$0 { controller.message = nil } }
        )) {
            Button(L10n.text("好"), role: .cancel) { controller.message = nil }
        } message: {
            Text(controller.message ?? "")
        }
        .tint(.bywayAccent)
    }
}

extension Color {
    /// 品牌色别名，沿用旧调用点；实际取值见 DesignSystem。
    static var bywayAccent: Color { .bywayBrand }
}
