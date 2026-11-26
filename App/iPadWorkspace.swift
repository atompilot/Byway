import SwiftUI

struct PadWorkspace: View {
    private static let brandIcon = BywayImage(named: "AppIcon60x60")
    @ObservedObject var controller: VPNController
    @ObservedObject var localControl: LANControl
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = Page.nodes
    @State private var sidebarOpen = false
    @State private var nodePath: [NodeListTarget] = []
    @State private var nodeSelection: NodeListTarget?
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var nodeActions = NodeActionPresentation()
    @State private var groupActions = NodeGroupActions()

    private enum Page: String, CaseIterable, Identifiable {
        case nodes, routing, privateNetwork, traffic, ai
        var id: Self { self }

        var title: String {
            switch self {
            case .nodes: L10n.text("节点")
            case .routing: L10n.text("分流")
            case .privateNetwork: L10n.text("私网")
            case .traffic: L10n.text("流量")
            case .ai: L10n.text("AI 控制")
            }
        }

        var symbol: String {
            switch self {
            case .nodes: "server.rack"
            case .routing: "arrow.triangle.branch"
            case .privateNetwork: "point.3.connected.trianglepath.dotted"
            case .traffic: "chart.bar.xaxis"
            case .ai: "slider.horizontal.3"
            }
        }
    }

    private enum Layout: Equatable {
        case wide, sidebar, compact

        init(size: CGSize) {
            if size.width >= 1_040 && size.width > size.height { self = .wide }
            else if size.width >= 680 { self = .sidebar }
            else { self = .compact }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = Layout(size: geometry.size)
            let drawerVisible = layout == .compact && sidebarOpen
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if layout != .compact {
                        sidebar(showClose: false)
                            .frame(width: layout == .wide ? 200 : 178)
                        Divider()
                    }
                    if page == .nodes {
                        nodeNavigation(layout)
                        if layout == .wide {
                            Divider()
                            detailNavigation
                        }
                    } else {
                        NavigationStack { pageContents(layout) }
                            .id(page)
                    }
                }
                .accessibilityHidden(drawerVisible)

                if drawerVisible {
                    Button { presentSidebar(false) } label: {
                        Color.black.opacity(0.26).ignoresSafeArea().contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("关闭侧栏"))

                    sidebar(showClose: true)
                        .frame(width: min(270, geometry.size.width * 0.78))
                        .shadow(color: .black.opacity(0.14), radius: 16, x: 4)
                        .transition(.move(edge: .leading))
                }
            }
            .onChange(of: layout) { _, _ in sidebarOpen = false }
        }
        .modifier(NodeActionPresenter(controller: controller, actions: $nodeActions))
        .modifier(NodeGroupActionPresenter(controller: controller, actions: $groupActions))
    }

    private func nodeNavigation(_ layout: Layout) -> some View {
        let path = Binding<[NodeListTarget]>(
            get: { layout == .wide ? [] : nodePath },
            set: { if layout != .wide { updatePath($0) } }
        )
        return NavigationStack(path: path) {
            nodeList
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if !controller.profile.nodes.isEmpty {
                            NodeBatchTestButton(controller: controller, compact: true).labelStyle(.titleOnly)
                        }
                        Button(L10n.text("添加节点"), systemImage: "plus") { nodeActions.sheet = .add }
                            .accessibilityIdentifier("ipad-add-node")
                            .disabled(!controller.canManage)
                    }
                }
                .modifier(PadSidebarButton(isVisible: layout == .compact, open: { presentSidebar(true) }))
                .navigationDestination(for: NodeListTarget.self) { target in
                    destination(target)
                        .modifier(PadSidebarButton(isVisible: layout == .compact, open: { presentSidebar(true) }))
                }
        }
        .frame(minWidth: layout == .wide ? 300 : nil, idealWidth: layout == .wide ? 345 : nil,
               maxWidth: layout == .wide ? 360 : .infinity)
    }

    private var detailNavigation: some View {
        let base = nodePath.first ?? nodeSelection
        return NavigationStack(path: Binding(
            get: { Array(nodePath.dropFirst()) },
            set: { if let base { updatePath([base] + $0) } }
        )) {
            Group {
                if let base { destination(base).id(base) }
                else {
                    ContentUnavailableView(L10n.text("选择节点或组"), systemImage: "square.stack",
                                           description: Text(L10n.text("从列表打开节点或节点组。")))
                }
            }
            .navigationDestination(for: NodeListTarget.self) { destination($0) }
        }
        .frame(maxWidth: .infinity)
    }

    private var nodeList: some View {
        List {
            if controller.profile.nodes.isEmpty && controller.profile.nodeSubscriptions.isEmpty {
                ContentUnavailableView(L10n.text("暂无节点"), systemImage: "server.rack")
            } else {
                NodeListSections(controller: controller, nodeActions: $nodeActions, groupActions: $groupActions,
                                 search: search, selection: nodeSelection,
                                 openNode: { open(.node($0)) }, openGroup: { open(.group($0)) })
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .top, spacing: 0) { searchBar }
        .navigationTitle(Page.nodes.title)
        .bywayInlineTitle()
        .refreshable { await controller.load() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L10n.text("搜索节点或组"), text: $search)
                #if os(macOS)
                .textFieldStyle(.plain)
                #endif
                .bywayNoAutocapitalization()
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
                .accessibilityIdentifier("ipad-node-search")
            if !search.isEmpty {
                Button(L10n.text("清除搜索"), systemImage: "xmark.circle.fill") { search = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        #if os(macOS)
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(Color.bywayFill, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.bywayAccent.opacity(searchFocused ? 0.45 : 0))
                .allowsHitTesting(false)
        }
        #else
        .padding(.horizontal, 11)
        .frame(minHeight: 40)
        .background(Color.bywayFill, in: RoundedRectangle(cornerRadius: 10))
        #endif
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func sidebar(showClose: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Group {
                    if let icon = Self.brandIcon {
                        Image(bywayImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.bywayAccent)
                    }
                }
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
                Text("Byway").font(.title3.weight(.semibold))
                Spacer(minLength: 0)
                if showClose {
                    Button(L10n.text("收起侧栏"), systemImage: "sidebar.leading") { presentSidebar(false) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.escape, modifiers: [])
                        .accessibilityIdentifier("ipad-close-sidebar")
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(Page.allCases) { entry in
                        Button {
                            searchFocused = false
                            page = entry
                            presentSidebar(false)
                        } label: {
                            Label(entry.title, systemImage: entry.symbol)
                                .font(.body.weight(page == entry ? .semibold : .regular))
                                .foregroundStyle(page == entry ? Color.bywayAccent : .primary)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .background(page == entry ? Color.bywayAccent.opacity(0.13) : .clear,
                                            in: RoundedRectangle(cornerRadius: 9))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(page == entry ? .isSelected : [])
                        .accessibilityIdentifier("ipad-sidebar-\(entry.rawValue)")
                    }
                }
            }
            Divider()
            connectionControls
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background {
            Color.bywaySidebarBackground
                .overlay(Color.bywayAccent.opacity(0.045))
                .ignoresSafeArea()
        }
        .accessibilityIdentifier("ipad-sidebar")
    }

    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(controller.connected ? Color.bywayAccent : .secondary)
                    .frame(width: 7, height: 7).accessibilityHidden(true)
                Text("VPN \(controller.statusLabel)").font(.footnote.weight(.semibold))
            }
            if controller.routesDirectly {
                Text(L10n.text("直连模式")).font(.caption).foregroundStyle(.secondary)
            } else if let node = controller.activeNode {
                Text("\(controller.connected ? L10n.text("出口") : L10n.text("已选")) \(node.name)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button {
                if !controller.hasConnectionProfile {
                    presentSidebar(false)
                    nodeActions.sheet = .add
                } else {
                    Task { await controller.toggleConnection() }
                }
            } label: {
                Text(connectionAction)
                    .font(.footnote.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("ipad-connection-control")
            .disabled(controller.busy || controller.status == .disconnecting)
            #if os(macOS)
            Divider().padding(.vertical, 3)
            macTakeoverControls
            #endif
        }
        .padding(.horizontal, 8)
    }

    #if os(macOS)
    /// Mac 版可选择系统代理、全流量或仅监听，三种方式共用同一份节点与分流配置。
    private var macTakeoverControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(L10n.text("接管方式"), selection: Binding(
                get: { controller.takeover },
                set: { value in Task { await controller.setTakeover(value) } }
            )) {
                ForEach(MacTakeover.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(controller.busy)
            .accessibilityIdentifier("mac-takeover-picker")

            Text(controller.localProxyAddress)
                .font(.caption2).foregroundStyle(.secondary)
                .textSelection(.enabled)

            switch controller.takeover {
            case .systemProxy:
                Text(systemProxyLabel)
                    .font(.caption2)
                    .foregroundStyle(controller.systemProxy == .off ? .secondary : Color.bywayAccent)
                HStack(spacing: 6) {
                    Button(L10n.text("设为系统代理")) { Task { await controller.applySystemProxy() } }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityIdentifier("mac-apply-system-proxy")
                    if controller.systemProxy != .off {
                        Button(L10n.text("关闭")) { Task { await controller.clearSystemProxy() } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .disabled(controller.busy)
            case .tun:
                Text(controller.connected ? L10n.text("已接管全部流量") : L10n.text("连接时请求一次管理员授权"))
                    .font(.caption2).foregroundStyle(.secondary)
            case .listenOnly:
                Text(L10n.text("在应用或终端里把代理设为 127.0.0.1:{0}。", MacSettings.mixedPort))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var systemProxyLabel: String {
        switch controller.systemProxy {
        case .off: L10n.text("未接管系统代理")
        case .byway(let port): L10n.text("已指向 Byway（{0}）", port)
        case .other: L10n.text("系统代理由其他应用接管")
        }
    }
    #endif

    private var connectionAction: String {
        if !controller.hasConnectionProfile { return L10n.text("添加节点") }
        if controller.connected || controller.status == .connecting {
            return controller.profile.privateNetwork?.enabled == true ? L10n.text("停用 VPN") : L10n.text("断开")
        }
        return L10n.text("连接")
    }

    @ViewBuilder private func pageContents(_ layout: Layout) -> some View {
        Group {
            switch page {
            case .nodes: EmptyView()
            case .routing:
                List { RoutingOverviewSection(controller: controller) }
                    .navigationTitle(page.title)
            case .privateNetwork:
                PrivateNetworkPage(controller: controller, wide: layout == .wide)
            case .traffic:
                List { TrafficSection(controller: controller) }
                    .navigationTitle(page.title)
            case .ai:
                LANControlEditor(control: localControl, vpn: controller)
            }
        }
        .bywayInlineTitle()
        .modifier(PadSidebarButton(isVisible: layout == .compact, open: { presentSidebar(true) }))
    }

    @ViewBuilder private func destination(_ target: NodeListTarget) -> some View {
        switch target {
        case .node(let id):
            NodeDetailsView(controller: controller, id: id, workspaceStyle: true,
                            onDeletion: { removeFromPath(target) })
        case .group(let id):
            NodeGroupDetail(controller: controller, id: id, openNode: { member in
                updatePath([target, .node(member)])
            }, onDeletion: { removeFromPath(target) })
        }
    }

    private func open(_ target: NodeListTarget) {
        searchFocused = false
        updatePath([target])
    }

    private func updatePath(_ path: [NodeListTarget]) {
        nodePath = path
        if let selection = path.last { nodeSelection = selection }
    }

    private func removeFromPath(_ target: NodeListTarget) {
        if let index = nodePath.firstIndex(of: target) { nodePath.removeSubrange(index...) }
        nodeSelection = nodePath.last
    }

    private func presentSidebar(_ shown: Bool) {
        searchFocused = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { sidebarOpen = shown }
    }
}

private struct PadSidebarButton: ViewModifier {
    let isVisible: Bool
    let open: () -> Void

    func body(content: Content) -> some View {
        content.toolbar {
            if isVisible {
                ToolbarItem(placement: .navigation) {
                    Button(L10n.text("打开侧栏"), systemImage: "sidebar.leading", action: open)
                        .accessibilityIdentifier("ipad-open-sidebar")
                }
            }
        }
    }
}
