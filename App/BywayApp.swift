import SwiftUI

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

private struct BywayRootView: View {
    @ObservedObject var controller: VPNController
    @ObservedObject var localControl: LANControl
    @Environment(\.scenePhase) private var scenePhase

    private var shouldPoll: Bool { scenePhase == .active && controller.connected }

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                PadWorkspace(controller: controller, localControl: localControl)
            } else {
                HomeView(controller: controller, localControl: localControl)
            }
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
            Button("好", role: .cancel) { controller.message = nil }
        } message: {
            Text(controller.message ?? "")
        }
        .tint(.bywayAccent)
    }
}

extension Color {
    static let bywayAccent = Color(red: 0.12, green: 0.50, blue: 0.43)
}
