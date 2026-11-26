#if os(macOS)
import SwiftUI

/// Mac 的主窗口：系统侧栏 + 原生内容区。
/// 节点页用「列表 + 详情」两栏，其余页面是设置式单栏，尽量贴合 macOS 自己的结构。
struct MacWorkspace: View {
    @ObservedObject var controller: VPNController
    @ObservedObject var localControl: LANControl
    @State private var page: MacPage = .nodes
    @State private var selection: NodeListTarget?
    @State private var search = ""
    @State private var nodeActions = NodeActionPresentation()
    @State private var groupActions = NodeGroupActions()

    init(controller: VPNController, localControl: LANControl,
         initialPage: MacPage = .nodes, initialNodeID: UUID? = nil) {
        self.controller = controller
        self.localControl = localControl
        _page = State(initialValue: initialPage)
        _selection = State(initialValue: initialNodeID.map { NodeListTarget.node($0) })
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 186, ideal: 200, max: 240)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .modifier(NodeActionPresenter(controller: controller, actions: $nodeActions, onDeletion: {
            if case .node = selection { selection = nil }
        }))
        .modifier(NodeGroupActionPresenter(controller: controller, actions: $groupActions, onDeletion: {
            if case .group = selection { selection = nil }
        }))
    }

    // MARK: 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: BywayStyle.Spacing.s) {
                brandIcon
                    .frame(width: 22, height: 22)
                Text("Byway")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BywayStyle.Spacing.m)
            .padding(.top, BywayStyle.Spacing.m)
            .padding(.bottom, BywayStyle.Spacing.s)

            VStack(spacing: 1) {
                ForEach(MacPage.allCases) { item in
                    MacSidebarRow(page: item, selected: page == item) { page = item }
                }
            }
            .padding(.horizontal, BywayStyle.Spacing.s)

            Spacer(minLength: 0)
            MacConnectionFooter(controller: controller, page: $page)
        }
        .background(Color.bywaySidebarBackground)
    }

    @ViewBuilder private var brandIcon: some View {
        if let icon = BywayImage(named: "AppIcon60x60") {
            Image(bywayImage: icon).resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.bywayBrand, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    // MARK: 内容

    @ViewBuilder private var detail: some View {
        switch page {
        case .nodes:
            MacNodeBrowser(controller: controller, selection: $selection, search: $search,
                           nodeActions: $nodeActions, groupActions: $groupActions)
        case .routing:
            NavigationStack { MacRoutingPage(controller: controller) }
        case .privateNetwork:
            NavigationStack { PrivateNetworkPage(controller: controller, wide: true) }
        case .traffic:
            NavigationStack { MacTrafficPage(controller: controller) }
        case .ai:
            NavigationStack { MacAIPage(control: localControl, vpn: controller) }
        }
    }
}

enum MacPage: String, CaseIterable, Identifiable {
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

private struct MacSidebarRow: View {
    let page: MacPage
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: BywayStyle.Spacing.s) {
                Image(systemName: page.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(selected ? Color.bywayBrand : .secondary)
                Text(page.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.bywayBrand : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BywayStyle.Spacing.s)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: BywayStyle.Radius.control, style: .continuous)
                    .fill(fill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("mac-sidebar-\(page.rawValue)")
    }

    private var fill: Color {
        if selected { return Color.bywayBrand.opacity(0.15) }
        if hovering { return Color.primary.opacity(0.05) }
        return .clear
    }
}

// MARK: - 侧栏底部连接区

private struct MacConnectionFooter: View {
    @ObservedObject var controller: VPNController
    @Binding var page: MacPage

    var body: some View {
        VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
            Divider()
            HStack(spacing: BywayStyle.Spacing.xs) {
                BywayStatusDot(connected: controller.connected)
                Text(controller.statusLabel)
                    .font(BywayStyle.Typography.metadata.weight(.semibold))
                Spacer(minLength: 0)
                if controller.connected {
                    Text(controller.takeover.title)
                        .font(BywayStyle.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
            }
            Text(exitSummary)
                .font(BywayStyle.Typography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(exitSummary)

            HStack(spacing: BywayStyle.Spacing.s) {
                Button(action: toggleConnection) {
                    Text(connectionTitle)
                        .frame(maxWidth: .infinity, minHeight: BywayStyle.Metrics.tapTarget)
                }
                .buttonStyle(MacProminentButtonStyle())
                .disabled(controller.busy || controller.status == .disconnecting)

                Menu {
                    Picker(L10n.text("接管方式"), selection: Binding(
                        get: { controller.takeover },
                        set: { value in Task { await controller.setTakeover(value) } }
                    )) {
                        ForEach(MacTakeover.allCases) { option in
                            Text(option.menuTitle).tag(option)
                        }
                    }
                    if controller.takeover == .systemProxy {
                        Divider()
                        if controller.systemProxy == .off {
                            Button(L10n.text("设为系统代理")) { Task { await controller.applySystemProxy() } }
                        } else {
                            Button(L10n.text("关闭系统代理")) { Task { await controller.clearSystemProxy() } }
                        }
                    }
                } label: {
                    Image(systemName: "switch.2")
                        .frame(width: BywayStyle.Metrics.tapTarget, height: BywayStyle.Metrics.tapTarget)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help(L10n.text("接管方式：{0}", controller.takeover.title))
                .accessibilityIdentifier("mac-takeover-menu")
            }

            Text(takeoverHint)
                .font(BywayStyle.Typography.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, BywayStyle.Spacing.m)
        .padding(.vertical, BywayStyle.Spacing.s)
        .background(.bar)
    }

    private var exitSummary: String {
        if controller.routesDirectly { return L10n.text("直连模式") }
        if let node = controller.activeNode {
            let verb = controller.connected ? L10n.text("出口") : L10n.text("已选")
            return "\(verb) \(node.name)"
        }
        return L10n.text("未选择节点")
    }

    private var connectionTitle: String {
        if !controller.hasConnectionProfile { return L10n.text("添加节点") }
        if controller.connected || controller.status == .connecting {
            return controller.profile.privateNetwork?.enabled == true ? L10n.text("停用 VPN") : L10n.text("断开")
        }
        return L10n.text("连接")
    }

    private var takeoverHint: String {
        switch controller.takeover {
        case .tun:
            return controller.connected ? L10n.text("全部流量经节点转发") : L10n.text("连接时请求一次管理员授权")
        case .systemProxy:
            switch controller.systemProxy {
            case .off: return L10n.text("未接管系统代理 · {0} 端口就绪", MacSettings.mixedPort)
            case .byway(let port): return L10n.text("系统代理指向 Byway（{0}）", port)
            case .other: return L10n.text("系统代理由其他应用接管")
            }
        case .listenOnly:
            return L10n.text("在应用里指定 127.0.0.1:{0}", MacSettings.mixedPort)
        }
    }

    private func toggleConnection() {
        if !controller.hasConnectionProfile {
            page = .nodes
            return
        }
        Task { await controller.toggleConnection() }
    }
}

// MARK: - 节点页

private struct MacNodeBrowser: View {
    @ObservedObject var controller: VPNController
    @Binding var selection: NodeListTarget?
    @Binding var search: String
    @Binding var nodeActions: NodeActionPresentation
    @Binding var groupActions: NodeGroupActions

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            detailPane
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(L10n.text("节点"))
    }

    private var listPane: some View {
        List {
            if controller.profile.nodes.isEmpty && controller.profile.nodeSubscriptions.isEmpty {
                ContentUnavailableView {
                    Label(L10n.text("暂无节点"), systemImage: "server.rack")
                } description: {
                    Text(L10n.text("导入节点或订阅后即可连接。"))
                } actions: {
                    Button(L10n.text("添加节点")) { nodeActions.sheet = .add }
                        .disabled(!controller.canManage)
                }
                .listRowSeparator(.hidden)
            } else {
                NodeListSections(controller: controller, nodeActions: $nodeActions, groupActions: $groupActions,
                                 search: search, selection: selection,
                                 openNode: { select(.node($0)) },
                                 openGroup: { select(.group($0)) })
            }
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, BywayStyle.Metrics.compactRowHeight)
        .searchable(text: $search, placement: .toolbar, prompt: L10n.text("搜索节点或组"))
        .onChange(of: controller.profile.nodes.count) { _, _ in validateSelection() }
        .toolbar {
            ToolbarItemGroup {
                if !controller.profile.nodes.isEmpty {
                    NodeBatchTestButton(controller: controller, compact: true)
                }
                Menu {
                    Button(L10n.text("添加节点"), systemImage: "plus") { nodeActions.sheet = .add }
                    Button(L10n.text("添加订阅"), systemImage: "dot.radiowaves.left.and.right") { nodeActions.sheet = .add }
                } label: {
                    Label(L10n.text("添加"), systemImage: "plus")
                }
                .disabled(!controller.canManage)
                .accessibilityIdentifier("mac-add-node")
            }
        }
    }

    @ViewBuilder private var detailPane: some View {
        switch selection {
        case .node(let id):
            MacNodeDetail(controller: controller, id: id, actions: $nodeActions, selection: $selection)
        case .group(let id):
            MacGroupDetail(controller: controller, id: id, actions: $groupActions, selection: $selection)
        case nil:
            ContentUnavailableView {
                Label(L10n.text("选择节点或组"), systemImage: "square.stack")
            } description: {
                Text(L10n.text("从左侧列表查看节点信息、测速或切换出口。"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func select(_ target: NodeListTarget) {
        selection = target
    }

    private func validateSelection() {
        guard let selection else { return }
        let groups = NodeListGroup.all(in: controller.profile)
        switch selection {
        case .node(let id):
            if !controller.profile.nodes.contains(where: { $0.id == id }) { self.selection = nil }
        case .group(let id):
            if !groups.contains(where: { $0.id == id }) { self.selection = nil }
        }
    }
}

private struct MacNodeDetail: View {
    @ObservedObject var controller: VPNController
    let id: UUID
    @Binding var actions: NodeActionPresentation
    @Binding var selection: NodeListTarget?

    private var node: ProxyNode? { controller.profile.nodes.first { $0.id == id } }
    private var isActive: Bool { controller.activeNode?.id == id }

    var body: some View {
        Group {
            if let node {
                ScrollView {
                    VStack(alignment: .leading, spacing: BywayStyle.Spacing.l) {
                        header(node)
                        actionRow(node)
                        metrics
                        connectionCard(node)
                        if actions.isDeleting { ProgressView(L10n.text("正在删除节点")) }
                        Spacer(minLength: 0)
                    }
                    .padding(BywayStyle.Metrics.pagePadding)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                ContentUnavailableView(L10n.text("节点已移除"), systemImage: "server.rack")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func header(_ node: ProxyNode) -> some View {
        HStack(alignment: .top, spacing: BywayStyle.Spacing.m) {
            VStack(alignment: .leading, spacing: BywayStyle.Spacing.xs) {
                Text(node.name)
                    .font(BywayStyle.Typography.pageTitle)
                    .lineLimit(2)
                    .accessibilityIdentifier("mac-node-detail-name")
                Text("\(node.protocolName.uppercased()) · \(node.host):\(node.port)")
                    .font(BywayStyle.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Menu {
                NodeMenuItems(controller: controller, node: node, actions: $actions)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityIdentifier("mac-node-more")
        }
    }

    private func actionRow(_ node: ProxyNode) -> some View {
        HStack(spacing: BywayStyle.Spacing.s) {
            if isActive {
                Label(controller.connected && !controller.routesDirectly ? L10n.text("当前使用") : L10n.text("已选为出口"),
                      systemImage: "checkmark.circle.fill")
                    .font(BywayStyle.Typography.rowTitle)
                    .foregroundStyle(Color.bywayBrand)
            } else {
                Button(L10n.text("使用此节点")) { Task { await controller.choose(node) } }
                    .buttonStyle(MacProminentButtonStyle())
                    .frame(width: 108)
                    .disabled(!controller.canManage || !controller.canSelectNode(node))
            }
            Button {
                Task { await controller.probe(node) }
            } label: {
                if controller.testingNodeID == id {
                    HStack(spacing: BywayStyle.Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("正在测试"))
                    }
                } else {
                    Label(L10n.text("测试延迟"), systemImage: "waveform.path")
                }
            }
            .buttonStyle(.bordered)
            .disabled(!controller.canTest)
        }
    }

    private var metrics: some View {
        let values = probeSummary
        return HStack(spacing: 0) {
            BywayMetricTile(title: L10n.text("最近延迟"), value: values.latency, symbol: "waveform.path")
            Divider().frame(height: 34)
            BywayMetricTile(title: L10n.text("出口 IP"), value: values.exitIP, symbol: "globe")
            Divider().frame(height: 34)
            BywayMetricTile(title: L10n.text("端口"), value: node.map { $0.port.formatted(.number.grouping(.never)) } ?? "—",
                            symbol: "number")
        }
        .padding(.vertical, BywayStyle.Spacing.s)
        .background(Color.bywaySubtleFill, in: RoundedRectangle(cornerRadius: BywayStyle.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BywayStyle.Radius.card, style: .continuous)
                .strokeBorder(Color.bywayHairline.opacity(0.5), lineWidth: 0.5)
        }
    }

    private func connectionCard(_ node: ProxyNode) -> some View {
        let groups = NodeListGroup.all(in: controller.profile)
            .filter { $0.nodes.contains { $0.id == node.id } }.map(\.name)
        return VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
            BywaySectionHeader(title: L10n.text("连接信息"))
            BywayCard {
                VStack(spacing: BywayStyle.Spacing.s) {
                    detailRow(L10n.text("服务器"), node.host, monospaced: true)
                    Divider()
                    detailRow(L10n.text("端口"), node.port.formatted(.number.grouping(.never)), monospaced: true)
                    if !groups.isEmpty {
                        Divider()
                        detailRow(L10n.text("所在组"), groups.joined(separator: "、"))
                    }
                }
            }
        }
    }

    private func detailRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(BywayStyle.Typography.rowTitle)
                .foregroundStyle(.secondary)
            Spacer(minLength: BywayStyle.Spacing.l)
            Text(value)
                .font(monospaced ? BywayStyle.Typography.monospacedValue : BywayStyle.Typography.rowTitle)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }

    private var probeSummary: (latency: String, exitIP: String) {
        switch controller.probes[id] {
        case .succeeded(let probe): ("\(probe.latencyMS) ms", probe.exitIP)
        case .failed: (L10n.text("测试未通过"), "—")
        case nil: (L10n.text("未测试"), "—")
        }
    }
}

private struct MacGroupDetail: View {
    @ObservedObject var controller: VPNController
    let id: NodeListGroup.ID
    @Binding var actions: NodeGroupActions
    @Binding var selection: NodeListTarget?

    private var group: NodeListGroup? { NodeListGroup.all(in: controller.profile).first { $0.id == id } }

    var body: some View {
        Group {
            if let group {
                ScrollView {
                    VStack(alignment: .leading, spacing: BywayStyle.Spacing.l) {
                        header(group)
                        if let subscription = group.subscription { subscriptionCard(subscription) }
                        membersCard(group)
                        Spacer(minLength: 0)
                    }
                    .padding(BywayStyle.Metrics.pagePadding)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                ContentUnavailableView(L10n.text("暂无节点"), systemImage: "square.stack")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func header(_ group: NodeListGroup) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: BywayStyle.Spacing.xs) {
                Text(group.name)
                    .font(BywayStyle.Typography.pageTitle)
                    .lineLimit(2)
                Text(L10n.text("{0} 个节点", group.nodes.count))
                    .font(BywayStyle.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                NodeGroupMenuItems(controller: controller, group: group, actions: $actions)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    private func subscriptionCard(_ item: NodeSubscription) -> some View {
        VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
            BywaySectionHeader(title: L10n.text("订阅"))
            BywayCard {
                VStack(spacing: BywayStyle.Spacing.s) {
                    row(L10n.text("地址"), item.address.host ?? "—", monospaced: true)
                    if let expires = item.usage?.expires {
                        Divider()
                        row(L10n.text("到期时间"), Date(timeIntervalSince1970: Double(expires)).formatted(date: .abbreviated, time: .omitted))
                    }
                    if let total = item.usage?.total {
                        Divider()
                        row(L10n.text("流量额度"), ByteCountFormatter.string(fromByteCount: total, countStyle: .decimal))
                    }
                }
            }
        }
    }

    private func membersCard(_ group: NodeListGroup) -> some View {
        VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
            HStack {
                BywaySectionHeader(title: L10n.text("节点"))
                Spacer()
                Button {
                    controller.toggleBatchTest(only: Set(group.nodes.map(\.id)))
                } label: {
                    Label(L10n.text("测试本组"), systemImage: "waveform.path")
                        .font(BywayStyle.Typography.metadata)
                }
                .buttonStyle(.link)
                .disabled(!controller.canTest || group.nodes.isEmpty)
            }
            BywayCard(padding: 0) {
                VStack(spacing: 0) {
                    if group.nodes.isEmpty {
                        Text(L10n.text("此组暂无节点"))
                            .font(BywayStyle.Typography.metadata)
                            .foregroundStyle(.secondary)
                            .padding(BywayStyle.Metrics.cardPadding)
                    }
                    ForEach(Array(group.nodes.enumerated()), id: \.element.id) { index, node in
                        memberRow(node)
                        if index < group.nodes.count - 1 {
                            Divider().padding(.leading, BywayStyle.Metrics.cardPadding)
                        }
                    }
                }
            }
        }
    }

    private func memberRow(_ node: ProxyNode) -> some View {
        let active = controller.activeNode?.id == node.id
        return Button {
            selection = .node(node.id)
        } label: {
            HStack(spacing: BywayStyle.Spacing.s) {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(active ? Color.bywayBrand : Color.secondary.opacity(0.45))
                Text(node.name)
                    .font(BywayStyle.Typography.rowTitle)
                    .lineLimit(1)
                if active {
                    Text(controller.connected && !controller.routesDirectly ? L10n.text("使用中") : L10n.text("已选出口"))
                        .font(BywayStyle.Typography.metadata)
                        .foregroundStyle(Color.bywayBrand)
                }
                Spacer(minLength: BywayStyle.Spacing.s)
                Text(status(of: node))
                    .font(BywayStyle.Typography.metadata.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, BywayStyle.Metrics.cardPadding)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func status(of node: ProxyNode) -> String {
        switch controller.probes[node.id] {
        case .succeeded(let probe): "\(probe.latencyMS) ms"
        case .failed: L10n.text("测试失败")
        case nil: node.protocolName.uppercased()
        }
    }

    private func row(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(title).font(BywayStyle.Typography.rowTitle).foregroundStyle(.secondary)
            Spacer(minLength: BywayStyle.Spacing.l)
            Text(value)
                .font(monospaced ? BywayStyle.Typography.monospacedValue : BywayStyle.Typography.rowTitle)
                .textSelection(.enabled)
        }
    }
}

// MARK: - 流量页

private struct MacTrafficPage: View {
    @ObservedObject var controller: VPNController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BywayStyle.Spacing.l) {
                VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
                    BywaySectionHeader(title: L10n.text("当前连接"))
                    BywayCard {
                        VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
                            HStack(spacing: 0) {
                                BywayMetricTile(title: L10n.text("下载"), value: format(controller.trafficRates?.download, rate: true),
                                                symbol: "arrow.down", emphasized: true)
                                Divider().frame(height: 40)
                                BywayMetricTile(title: L10n.text("上传"), value: format(controller.trafficRates?.upload, rate: true),
                                                symbol: "arrow.up", emphasized: true)
                            }
                            .opacity(controller.connected ? 1 : 0.6)
                            if !controller.connected {
                                Text(L10n.text("连接后显示实时速率"))
                                    .font(BywayStyle.Typography.metadata)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
                    BywaySectionHeader(title: L10n.text("用量"))
                    BywayCard {
                        VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
                            HStack(spacing: 0) {
                                BywayMetricTile(title: L10n.text("本次连接"), value: format(controller.trafficSession?.total))
                                Divider().frame(height: 34)
                                BywayMetricTile(title: L10n.text("累计"), value: format(controller.trafficTotal?.total))
                            }
                            HStack(spacing: 0) {
                                BywayMetricTile(title: L10n.text("上传"), value: format(controller.trafficTotal?.upload), symbol: "arrow.up")
                                Divider().frame(height: 26)
                                BywayMetricTile(title: L10n.text("下载"), value: format(controller.trafficTotal?.download), symbol: "arrow.down")
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
                    BywaySectionHeader(title: L10n.text("明细"))
                    BywayCard(padding: 0) {
                        VStack(spacing: 0) {
                            NavigationLink { TrafficHistoryView(controller: controller) } label: {
                                linkRow(L10n.text("流量历史"), detail: L10n.text("按小时、按天的上传下载"), symbol: "chart.bar.xaxis")
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, BywayStyle.Metrics.cardPadding)
                            NavigationLink { ConnectionDiagnosticsView(controller: controller) } label: {
                                linkRow(L10n.text("连接与排障"), detail: L10n.text("活跃连接与内核日志"), symbol: "network")
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, BywayStyle.Metrics.cardPadding)
                            NavigationLink { BandwidthTestPage(controller: controller) } label: {
                                linkRow(L10n.text("带宽测速"), detail: L10n.text("通过当前节点测试上下行"), symbol: "speedometer")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(BywayStyle.Metrics.pagePadding)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(L10n.text("流量"))
    }

    private func linkRow(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: BywayStyle.Spacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.bywayBrand)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(BywayStyle.Typography.rowTitle)
                Text(detail).font(BywayStyle.Typography.metadata).foregroundStyle(.secondary)
            }
            Spacer(minLength: BywayStyle.Spacing.s)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, BywayStyle.Metrics.cardPadding)
        .frame(minHeight: 38)
        .contentShape(Rectangle())
    }

    private func format(_ count: Int64?, rate: Bool = false) -> String {
        guard let count else { return "—" }
        let amount = count == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: count, countStyle: .decimal)
        return rate ? "\(amount)/s" : amount
    }
}

// 带宽测速页在 MeasurementsViews 里是 iPhone 的列表样式，Mac 用同一份数据另写一个卡片版。
private struct BandwidthTestPage: View {
    @ObservedObject var controller: VPNController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BywayStyle.Spacing.l) {
                BywayCard {
                    HStack {
                        VStack(alignment: .leading, spacing: BywayStyle.Spacing.xs) {
                            Text(L10n.text("测试节点"))
                                .font(BywayStyle.Typography.metadata).foregroundStyle(.secondary)
                            Text(controller.activeNode?.name ?? L10n.text("未选择节点"))
                                .font(BywayStyle.Typography.rowTitleEmphasized)
                        }
                        Spacer()
                        Button {
                            Task { await controller.testBandwidth() }
                        } label: {
                            if controller.measuringBandwidth {
                                HStack(spacing: BywayStyle.Spacing.xs) {
                                    ProgressView().controlSize(.small)
                                    Text(L10n.text("正在测速"))
                                }
                            } else {
                                Text(L10n.text("开始测速"))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!controller.canTestBandwidth || controller.activeNode == nil)
                    }
                }
                if let measurement = controller.bandwidth {
                    BywayCard {
                        HStack(spacing: 0) {
                            BywayMetricTile(title: L10n.text("下载"), value: speed(measurement.result.downloadBitsPerSecond), emphasized: true)
                            Divider().frame(height: 40)
                            BywayMetricTile(title: L10n.text("上传"), value: speed(measurement.result.uploadBitsPerSecond), emphasized: true)
                        }
                    }
                }
                if let error = controller.bandwidthError {
                    Text(error).font(BywayStyle.Typography.metadata).foregroundStyle(.secondary)
                }
                Text(controller.connected ? L10n.text("测试会通过当前节点传输约 5 MB 数据。") : L10n.text("连接 VPN 后可测当前节点的上传和下载速度。"))
                    .font(BywayStyle.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            .padding(BywayStyle.Metrics.pagePadding)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(L10n.text("带宽测速"))
    }

    private func speed(_ bitsPerSecond: Int64) -> String {
        let megabits = Double(bitsPerSecond) / 1_000_000
        return "\(megabits.formatted(.number.precision(.fractionLength(0...2)))) Mbps"
    }
}

// MARK: - 分流页

private struct MacRoutingPage: View {
    @ObservedObject var controller: VPNController

    var body: some View {
        Form {
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
                .accessibilityIdentifier("mac-global-routing")

                NavigationLink {
                    ConfigurationEditor(controller: controller)
                } label: {
                    LabeledContent {
                        Text(activeConfiguration)
                    } label: {
                        Label(L10n.text("分流配置"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                }
                .accessibilityIdentifier("mac-routing-configuration")

                NavigationLink {
                    DNSSettingsView(controller: controller)
                } label: {
                    LabeledContent {
                        Text(dnsStatus)
                    } label: {
                        Label("DNS", systemImage: "network")
                    }
                }
                .accessibilityIdentifier("mac-dns-settings")
            } header: {
                Text(L10n.text("当前生效"))
            } footer: {
                Text(L10n.text("规则按顺序首命中生效，PROXY 使用节点页当前选择的出口。"))
            }

            Section(L10n.text("当前场景")) {
                if let network = controller.routingNetwork {
                    LabeledContent(network.title, value: controller.effectiveRouting.mode.title)
                    let group = controller.profile.globalRoutingSettings.groups.first {
                        $0.id == controller.effectiveRouting.groupID
                    }
                    LabeledContent(L10n.text("生效节点组"), value: group?.name ?? L10n.text("全部节点"))
                } else {
                    Text(L10n.text("未检测到网络类型")).foregroundStyle(.secondary)
                }
            }
        }
        .bywaySettingsForm()
        .frame(maxWidth: 700, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .navigationTitle(L10n.text("分流"))
    }

    private var activeConfiguration: String {
        let library = controller.profile.savedRouting
        return library.configurations.first { $0.id == library.activeID }?.name ?? L10n.text("默认")
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
}

// MARK: - AI 控制页

private struct MacAIPage: View {
    @ObservedObject var control: LANControl
    @ObservedObject var vpn: VPNController
    @Environment(\.openURL) private var openURL
    @State private var device: DeviceInfo?
    @State private var editing = false
    @State private var draft = ""
    @State private var nameError: String?
    @State private var showRelay = false
    @State private var copiedInstruction = false
    @State private var copiedLink = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BywayStyle.Spacing.l) {
                deviceCard
                accessCard
                exitCard
                if let address = control.address {
                    webCard(address)
                }
                otherCard
                Spacer(minLength: 0)
            }
            .padding(BywayStyle.Metrics.pagePadding)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(L10n.text("AI 控制"))
        .task {
            DeviceIdentityStore.observeNameChanges()
            refreshDevice()
        }
        .onReceive(NotificationCenter.default.publisher(for: DeviceIdentityStore.nameDidChange)
            .receive(on: RunLoop.main)) { _ in refreshDevice() }
        .onChange(of: control.token) { _, _ in copiedInstruction = false }
        .onChange(of: control.address) { _, _ in
            copiedInstruction = false
            copiedLink = false
        }
        .sheet(isPresented: $showRelay) {
            RelayEditor(configuration: vpn.profile.relay, editable: vpn.canEdit, save: vpn.setRelay)
        }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
            BywaySectionHeader(title: L10n.text("当前设备"))
            BywayCard {
                VStack(spacing: BywayStyle.Spacing.s) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.text("识别码"))
                            .font(BywayStyle.Typography.rowTitle)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: BywayStyle.Spacing.l)
                        Text(device?.shortCode ?? "—")
                            .font(BywayStyle.Typography.monospacedValue)
                            .textSelection(.enabled)
                    }
                    Divider()
                    if editing {
                        HStack(spacing: BywayStyle.Spacing.s) {
                            TextField(L10n.text("设备名称"), text: $draft)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(saveName)
                            Button(L10n.text("保存"), action: saveName)
                                .buttonStyle(.borderedProminent)
                                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button(L10n.text("取消")) {
                                editing = false
                                nameError = nil
                            }
                            .buttonStyle(.borderless)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            Text(L10n.text("设备名称"))
                                .font(BywayStyle.Typography.rowTitle)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: BywayStyle.Spacing.l)
                            Text(device?.displayName ?? "—")
                                .font(BywayStyle.Typography.rowTitle)
                                .textSelection(.enabled)
                            Button(L10n.text("修改")) {
                                draft = device?.displayName ?? ""
                                nameError = nil
                                editing = true
                            }
                            .buttonStyle(MacInlineButtonStyle())
                            .disabled(device == nil)
                        }
                    }
                    if let nameError {
                        Text(nameError)
                            .font(BywayStyle.Typography.metadata)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var accessCard: some View {
        VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
            BywaySectionHeader(title: L10n.text("把 Byway 接入电脑上的 AI"))
            BywayCard {
                VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
                    Toggle(L10n.text("允许局域网控制"), isOn: Binding(
                        get: { control.enabled },
                        set: { control.setEnabled($0, vpn: vpn) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!vpn.ready)
                    .accessibilityIdentifier("lan-control-toggle")

                    if control.enabled {
                        HStack(alignment: .firstTextBaseline) {
                            Text(L10n.text("状态")).foregroundStyle(.secondary)
                            Spacer(minLength: BywayStyle.Spacing.l)
                            Text(control.state).multilineTextAlignment(.trailing)
                        }
                        .font(BywayStyle.Typography.metadata)

                        Toggle(L10n.text("允许局域网发现"), isOn: Binding(
                            get: { control.discoveryEnabled },
                            set: { control.setDiscoveryEnabled($0, vpn: vpn) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityIdentifier("lan-discovery-toggle")

                        if let address = control.address {
                            HStack(alignment: .firstTextBaseline) {
                                Text(L10n.text("API 地址")).foregroundStyle(.secondary)
                                Spacer(minLength: BywayStyle.Spacing.l)
                                Text(address)
                                    .font(BywayStyle.Typography.monospacedValue)
                                    .textSelection(.enabled)
                            }
                            Button {
                                BywayPasteboard.copy(instruction(address))
                                copiedInstruction = true
                            } label: {
                                Label(copiedInstruction ? L10n.text("接入指令已复制") : L10n.text("复制接入指令"), systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("lan-control-copy")
                        }
                    }

                    Text(control.enabled
                         ? L10n.text("复制后直接粘贴给电脑上的 AI。VPN 连接期间锁屏也可访问；断开后接口只在 Byway 前台开放。")
                         : L10n.text("开启后可复制接入指令，交给同一 Wi-Fi 上的电脑 AI 管理节点和代理设置。请只在信任的 Wi-Fi 上使用。"))
                        .font(BywayStyle.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var exitCard: some View {
        VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
            BywaySectionHeader(title: L10n.text("出口与连接"))
            BywayCard {
                VStack(spacing: BywayStyle.Spacing.s) {
                    row(L10n.text("已选代理节点"), vpn.activeNode?.name ?? L10n.text("未选择节点"))
                    Divider()
                    row(L10n.text("VPN 状态"), vpn.statusLabel)
                    Divider()
                    row(L10n.text("接管方式"), vpn.takeover.title)
                }
            }
        }
    }

    private func webCard(_ address: String) -> some View {
        let url = URL(string: control.discovery?.preferredUrl ?? address + "/")
        return VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
            BywaySectionHeader(title: L10n.text("管理网页"))
            BywayCard {
                VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
                    if let url {
                        row(L10n.text("首选地址"), url.absoluteString, monospaced: true)
                    }
                    if control.discoveryEnabled && control.discovery?.mdnsUrl == nil {
                        Text(control.discovery?.status == "unavailable" ? L10n.text("mDNS 不可用，使用 IP 地址。") : L10n.text("正在发布 mDNS 地址。"))
                            .font(BywayStyle.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: BywayStyle.Spacing.s) {
                        Button(L10n.text("打开管理网页")) {
                            if let url { openURL(url) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!vpn.connected)
                        .accessibilityIdentifier("open-management-web")
                        Button(copiedLink ? L10n.text("网页链接已复制") : L10n.text("复制网页链接")) {
                            if let url { BywayPasteboard.copy(url: url) }
                            copiedLink = true
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("copy-management-link")
                    }
                    if !vpn.connected {
                        Text(L10n.text("连接 VPN 后可用本机浏览器打开；Byway 保持前台时其他设备也可访问。"))
                            .font(BywayStyle.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var otherCard: some View {
        VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
            BywaySectionHeader(title: L10n.text("其他"))
            BywayCard(padding: 0) {
                VStack(spacing: 0) {
                    NavigationLink { LANCallLogView(controller: vpn) } label: {
                        HStack {
                            Label(L10n.text("调用日志"), systemImage: "list.bullet.rectangle")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, BywayStyle.Metrics.cardPadding)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, BywayStyle.Metrics.cardPadding)
                    Button {
                        showRelay = true
                    } label: {
                        HStack {
                            Label(L10n.text("中继控制设置"), systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, BywayStyle.Metrics.cardPadding)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(BywayStyle.Typography.rowTitle)
                .foregroundStyle(.secondary)
            Spacer(minLength: BywayStyle.Spacing.l)
            Text(value)
                .font(monospaced ? BywayStyle.Typography.monospacedValue : BywayStyle.Typography.rowTitle)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func instruction(_ address: String) -> String {
        L10n.text("请读取 {0}/v1/guide 了解 Byway 的操作接口。\nAuthorization: Bearer {1}", address, control.token)
    }

    private func refreshDevice() {
        device = try? DeviceIdentityStore.local().read()
    }

    private func saveName() {
        do {
            device = try DeviceIdentityStore.local().rename(to: draft)
            editing = false
            nameError = nil
        } catch {
            nameError = error.localizedDescription
        }
    }
}
#endif
