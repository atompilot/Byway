import SwiftUI

struct PadWorkspace: View {
    private static let brandIcon = UIImage(named: "AppIcon60x60")
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
            case .nodes: "节点"
            case .routing: "分流"
            case .privateNetwork: "私网"
            case .traffic: "流量"
            case .ai: "AI 控制"
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
                    .accessibilityLabel("关闭侧栏")

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
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if !controller.profile.nodes.isEmpty {
                            NodeBatchTestButton(controller: controller, compact: true).labelStyle(.titleOnly)
                        }
                        Button("添加节点", systemImage: "plus") { nodeActions.sheet = .add }
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
                    ContentUnavailableView("选择节点或组", systemImage: "square.stack",
                                           description: Text("从列表打开节点或节点组。"))
                }
            }
            .navigationDestination(for: NodeListTarget.self) { destination($0) }
        }
        .frame(maxWidth: .infinity)
    }

    private var nodeList: some View {
        List {
            if controller.profile.nodes.isEmpty && controller.profile.nodeSubscriptions.isEmpty {
                ContentUnavailableView("暂无节点", systemImage: "server.rack")
            } else {
                NodeListSections(controller: controller, nodeActions: $nodeActions, groupActions: $groupActions,
                                 search: search, selection: nodeSelection,
                                 openNode: { open(.node($0)) }, openGroup: { open(.group($0)) })
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .top, spacing: 0) { searchBar }
        .navigationTitle(Page.nodes.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await controller.load() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("搜索节点或组", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
                .accessibilityIdentifier("ipad-node-search")
            if !search.isEmpty {
                Button("清除搜索", systemImage: "xmark.circle.fill") { search = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 40)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
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
                        Image(uiImage: icon).resizable().scaledToFit()
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
                    Button("收起侧栏", systemImage: "sidebar.leading") { presentSidebar(false) }
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
            Color(uiColor: .secondarySystemGroupedBackground)
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
                Text("直连模式").font(.caption).foregroundStyle(.secondary)
            } else if let node = controller.activeNode {
                Text("\(controller.connected ? "出口" : "已选") \(node.name)")
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
        }
        .padding(.horizontal, 8)
    }

    private var connectionAction: String {
        if !controller.hasConnectionProfile { return "添加节点" }
        if controller.connected || controller.status == .connecting {
            return controller.profile.privateNetwork?.enabled == true ? "停用 VPN" : "断开"
        }
        return "连接"
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
        .navigationBarTitleDisplayMode(.inline)
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
                ToolbarItem(placement: .topBarLeading) {
                    Button("打开侧栏", systemImage: "sidebar.leading", action: open)
                        .accessibilityIdentifier("ipad-open-sidebar")
                }
            }
        }
    }
}
