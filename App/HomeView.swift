import SwiftUI

struct HomeView: View {
    @ObservedObject var controller: VPNController
    @ObservedObject var localControl: LANControl
    @State private var nodeActions = NodeActionPresentation()
    @State private var groupActions = NodeGroupActions()
    @State private var openedGroup: NodeListGroup.ID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    connectionCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                RoutingOverviewSection(controller: controller)

                Section {
                    NavigationLink {
                        PrivateNetworkPage(controller: controller)
                    } label: {
                        LabeledContent {
                            Text(controller.connected && controller.profile.privateNetwork?.enabled == true
                                 ? controller.privateNetworkSummary ?? L10n.text("正在连接")
                                 : PrivateNetworkSettingsView(controller.profile.privateNetwork).state)
                        } label: {
                            Label(L10n.text("私网"), systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    }
                    .accessibilityIdentifier("private-network")
                }

                TrafficSection(controller: controller)

                Section {
                    NavigationLink {
                        SubscriptionsView(controller: controller)
                    } label: {
                        LabeledContent(L10n.text("订阅"), value: "\(controller.profile.nodeSubscriptions.count)")
                    }
                    .accessibilityIdentifier("subscriptions")
                }

                if !controller.profile.nodes.isEmpty || !controller.profile.nodeSubscriptions.isEmpty {
                    Section {
                        NodeBatchTestButton(controller: controller)
                    } header: {
                        HStack {
                            Text(L10n.text("节点"))
                            Spacer()
                            Button {
                                nodeActions.sheet = .add
                            } label: {
                                Image(systemName: "plus")
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel(L10n.text("添加节点"))
                            .disabled(!controller.canManage)
                        }
                    }
                    NodeListSections(controller: controller, nodeActions: $nodeActions, groupActions: $groupActions,
                                     openGroup: { openedGroup = $0 })
                }

                Section {
                    NavigationLink {
                        LANControlEditor(control: localControl, vpn: controller)
                    } label: {
                        LabeledContent {
                            Text(localControl.enabled ? localControl.state : L10n.text("局域网"))
                        } label: {
                            Label(L10n.text("AI 控制"), systemImage: "slider.horizontal.3")
                        }
                    }
                    .accessibilityIdentifier("ai-control")
                }
            }
            .bywayInsetGroupedList()
            .navigationTitle("Byway")
            .bywayInlineTitle()
            .navigationDestination(item: $openedGroup) { NodeGroupDetail(controller: controller, id: $0) }
            .refreshable { await controller.load() }
            .modifier(NodeActionPresenter(controller: controller, actions: $nodeActions))
            .modifier(NodeGroupActionPresenter(controller: controller, actions: $groupActions))
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.connected ? Color(red: 0.48, green: 0.91, blue: 0.71) : Color.white.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(controller.statusLabel)
                    .font(.subheadline.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(connectionTitle)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .lineLimit(2)
                if let node = controller.activeNode, !controller.routesDirectly {
                    Text(node.host).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
                        .font(.callout)
                }
            }
            Button {
                if needsProxyNode {
                    nodeActions.sheet = .add
                } else {
                    Task { await controller.toggleConnection() }
                }
            } label: {
                Label(connectionActionLabel, systemImage: needsProxyNode ? "plus" : "power")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 39)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.70, green: 0.94, blue: 0.77))
            .foregroundStyle(Color(red: 0.04, green: 0.22, blue: 0.18))
            .disabled(controller.busy || controller.status == .disconnecting)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 26)
                .fill(LinearGradient(colors: [
                    Color(red: 0.06, green: 0.20, blue: 0.17),
                    Color(red: 0.08, green: 0.34, blue: 0.29)
                ], startPoint: .bottomLeading, endPoint: .topTrailing))
                .overlay(alignment: .trailing) {
                    TrailMark()
                        .stroke(Color.white.opacity(0.17), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 125)
                        .padding(.trailing, 28)
                        .accessibilityHidden(true)
                }
        }
    }

    private var connectionTitle: String {
        if controller.activeNode == nil, !needsProxyNode { return L10n.text("私网") }
        guard let node = controller.activeNode else { return L10n.text("暂无节点") }
        return controller.routesDirectly ? L10n.text("直连模式") : node.name
    }

    private var connectionActionLabel: String {
        if needsProxyNode { return L10n.text("添加节点") }
        if controller.connected || controller.status == .connecting {
            return controller.profile.privateNetwork?.enabled == true ? L10n.text("停用 VPN") : L10n.text("断开")
        }
        return L10n.text("连接")
    }

    private var needsProxyNode: Bool {
        !controller.hasConnectionProfile
    }

}

struct RoutingOverviewSection: View {
    @ObservedObject var controller: VPNController

    var body: some View {
        Section {
            NavigationLink {
                GlobalRoutingView(controller: controller)
            } label: {
                LabeledContent {
                    Text(controller.profile.globalRoutingSettings.mode.title)
                } label: {
                    Label(L10n.text("全局路由"), systemImage: "arrow.triangle.branch")
                }
            }
            .accessibilityIdentifier("global-routing")

            NavigationLink {
                ConfigurationEditor(controller: controller)
            } label: {
                LabeledContent {
                    Text(configurationStatus)
                } label: {
                    Label(L10n.text("分流配置"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
            }
            .accessibilityIdentifier("routing-configuration")

            NavigationLink {
                DNSSettingsView(controller: controller)
            } label: {
                LabeledContent {
                    Text(dnsStatus)
                } label: {
                    Label("DNS", systemImage: "network")
                }
            }
            .accessibilityIdentifier("dns-settings")
        }
    }

    private var dnsStatus: String {
        let settings = controller.profile.dnsSettings
        if settings.mode == .manual, let server = settings.selected { return server.name }
        if settings.mode == .configuration, controller.profile.importedConfiguration?.enabled != true,
           controller.profile.routingSettings.dnsServer == ProxyRouting.defaultDNSServer {
            return DNSSettings.Mode.automatic.title
        }
        return settings.mode.title
    }

    private var configurationStatus: String {
        let library = controller.profile.savedRouting
        return library.configurations.first { $0.id == library.activeID }?.name ?? L10n.text("默认")
    }
}

private struct TrailMark: Shape {
    func path(in rect: CGRect) -> Path {
        let x = rect.width
        let y = rect.height
        return Path { path in
            path.move(to: CGPoint(x: x * 0.06, y: y * 0.82))
            path.addCurve(to: CGPoint(x: x * 0.94, y: y * 0.17),
                          control1: CGPoint(x: x * 0.24, y: y * 0.41),
                          control2: CGPoint(x: x * 0.80, y: y * 0.62))
            path.move(to: CGPoint(x: x * 0.12, y: y * 0.78))
            path.addCurve(to: CGPoint(x: x * 0.92, y: y * 0.57),
                          control1: CGPoint(x: x * 0.51, y: y * 0.59),
                          control2: CGPoint(x: x * 0.75, y: y * 0.81))
        }
    }
}
