import SwiftUI

struct NodeListGroup: Identifiable {
    enum ID: Hashable {
        case ungrouped, manual(UUID), subscription(UUID)

        var storageKey: String {
            switch self {
            case .ungrouped: "ungrouped"
            case .manual(let id): "manual-\(id.uuidString.lowercased())"
            case .subscription(let id): "subscription-\(id.uuidString.lowercased())"
            }
        }
    }

    let id: ID
    let name: String
    let nodes: [ProxyNode]
    var subscription: NodeSubscription?
    var manualGroup: RoutingGroup?

    static func all(in profile: BywayProfile) -> [Self] {
        let nodesByID = Dictionary(uniqueKeysWithValues: profile.nodes.map { ($0.id, $0) })
        let subscriptionIDs = Set(profile.nodeSubscriptions.map(\.id))
        let manual = profile.globalRoutingSettings.groups.filter { !subscriptionIDs.contains($0.id) }.map { group in
            Self(id: .manual(group.id), name: group.name,
                 nodes: group.nodeIDs.compactMap { nodesByID[$0] }, manualGroup: group)
        }
        let subscriptions = profile.nodeSubscriptions.map { item in
            Self(id: .subscription(item.id), name: item.name, nodes: item.members(in: profile), subscription: item)
        }
        let groups = manual + subscriptions
        let grouped = Set(groups.flatMap { $0.nodes.map(\.id) })
        let ungrouped = profile.nodes.filter { !grouped.contains($0.id) }
        return ungrouped.isEmpty ? groups : [Self(id: .ungrouped, name: L10n.text("未分组"), nodes: ungrouped)] + groups
    }
}

struct NodeGroupDetail: View {
    @ObservedObject var controller: VPNController
    let id: NodeListGroup.ID
    var openNode: ((UUID) -> Void)?
    var onDeletion: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var nodeActions = NodeActionPresentation()
    @State private var groupActions = NodeGroupActions()

    private var group: NodeListGroup? { NodeListGroup.all(in: controller.profile).first { $0.id == id } }

    var body: some View {
        List {
            if let group {
                if let subscription = group.subscription {
                    subscriptionInfo(subscription)
                }
                Section(L10n.text("节点（{0}）", group.nodes.count)) {
                    if let progress = controller.batchProgress {
                        Button(L10n.text("停止测试 · {0}/{1}", progress.completed, progress.total), systemImage: "stop.circle") {
                            controller.toggleBatchTest()
                        }
                        .disabled(controller.stoppingBatch)
                    }
                    ForEach(group.nodes) { node in
                        member(node)
                        .accessibilityAddTraits(controller.activeNode?.id == node.id ? .isSelected : [])
                        .contextMenu {
                            NodeMenuItems(controller: controller, node: node, actions: $nodeActions)
                        }
                    }
                    if group.nodes.isEmpty { Text(L10n.text("此组暂无节点")).foregroundStyle(.secondary) }
                }
            } else {
                ContentUnavailableView(L10n.text("暂无节点"), systemImage: "square.stack")
            }
        }
        .navigationTitle(group?.name ?? L10n.text("节点组"))
        .bywayInlineTitle()
        .toolbar {
            if let group {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        NodeGroupMenuItems(controller: controller, group: group, actions: $groupActions)
                    } label: {
                        Label(L10n.text("更多"), systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    }
                    .accessibilityIdentifier("node-group-more")
                }
            }
        }
        .modifier(NodeActionPresenter(controller: controller, actions: $nodeActions))
        .modifier(NodeGroupActionPresenter(controller: controller, actions: $groupActions, onDeletion: {
            if let onDeletion { onDeletion() }
            else { dismiss() }
        }))
    }

    @ViewBuilder private func member(_ node: ProxyNode) -> some View {
        if let openNode {
            Button { openNode(node.id) } label: {
                LabeledContent(node.name, value: status(of: node))
            }
            .foregroundStyle(.primary)
        } else {
            NavigationLink {
                NodeDetailsView(controller: controller, id: node.id)
            } label: {
                LabeledContent(node.name, value: status(of: node))
            }
        }
    }

    private func status(of node: ProxyNode) -> String {
        switch controller.probes[node.id] {
        case .succeeded(let probe): "\(probe.latencyMS) ms"
        case .failed: L10n.text("测试失败")
        case nil: node.id == controller.activeNode?.id ? L10n.text("当前") : node.host
        }
    }

    private func subscriptionInfo(_ item: NodeSubscription) -> some View {
        Section(L10n.text("订阅信息")) {
            if let host = item.address.host { LabeledContent(L10n.text("订阅服务器"), value: host) }
            LabeledContent(L10n.text("最近刷新"), value: item.refreshedAt.formatted(date: .abbreviated, time: .shortened))
            if let usage = item.usage {
                usageRow(L10n.text("剩余流量"), usage.remaining)
                usageRow(L10n.text("总额度"), usage.total)
                usageRow(L10n.text("上传"), usage.upload)
                usageRow(L10n.text("下载"), usage.download)
                if let expires = usage.expires, expires > 0 {
                    LabeledContent(L10n.text("到期时间"), value: Date(timeIntervalSince1970: Double(expires)).formatted())
                }
            }
        }
    }

    @ViewBuilder private func usageRow(_ title: String, _ value: Int64?) -> some View {
        if let value { LabeledContent(title, value: ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal)) }
    }
}

struct NodeGroupActions {
    enum Sheet: Identifiable {
        case add, editGroup(RoutingGroup), editSubscription(NodeSubscription), share(NodeShareItem)

        var id: String {
            switch self {
            case .add: "add"
            case .editGroup: "group"
            case .editSubscription: "subscription"
            case .share: "share"
            }
        }
    }

    var sheet: Sheet?
    var deletion: NodeListGroup?
    var progress: String?
}

struct NodeGroupMenuItems: View {
    @ObservedObject var controller: VPNController
    let group: NodeListGroup
    @Binding var actions: NodeGroupActions

    private var canManage: Bool { controller.canManage && actions.progress == nil }

    var body: some View {
        if let subscription = group.subscription {
            Button(L10n.text("编辑订阅"), systemImage: "pencil") { actions.sheet = .editSubscription(subscription) }.disabled(!canManage)
            Button(L10n.text("刷新订阅"), systemImage: "arrow.clockwise") { refresh(subscription.id) }.disabled(!canManage)
        } else if let manual = group.manualGroup {
            Button(L10n.text("编辑节点组"), systemImage: "pencil") { actions.sheet = .editGroup(manual) }.disabled(!canManage)
        } else {
            Button(L10n.text("添加节点"), systemImage: "plus") { actions.sheet = .add }.disabled(!canManage)
        }

        Button(L10n.text("测试本组节点"), systemImage: "waveform.path") {
            controller.toggleBatchTest(only: Set(group.nodes.map(\.id)))
        }
        .disabled(!controller.canTest || actions.progress != nil || group.nodes.isEmpty)

        Button(group.subscription == nil ? L10n.text("分享节点组") : L10n.text("分享订阅"), systemImage: "qrcode", action: share)
            .disabled(group.subscription == nil && group.nodes.isEmpty)

        if group.id != .ungrouped {
            Divider()
            Button(group.subscription == nil ? L10n.text("删除节点组") : L10n.text("删除订阅"), systemImage: "trash", role: .destructive) {
                actions.deletion = group
            }
            .disabled(!canManage)
        }
    }

    private func share() {
        do {
            let link = try group.subscription.map(NodeShare.subscription) ?? NodeShare.group(name: group.name, nodes: group.nodes)
            actions.sheet = .share(NodeShareItem(link: link))
        } catch { controller.message = error.localizedDescription }
    }

    private func refresh(_ id: UUID) {
        actions.progress = L10n.text("正在刷新订阅")
        Task {
            defer { actions.progress = nil }
            do { try await controller.manage("POST", "/v1/subscriptions/\(id.uuidString)/refresh") }
            catch { controller.message = error.localizedDescription }
        }
    }
}

struct NodeGroupActionPresenter: ViewModifier {
    @ObservedObject var controller: VPNController
    @Binding var actions: NodeGroupActions
    var onDeletion: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.sheet) { destination in
                switch destination {
                case .add:
                    NodeEditor(controller: controller)
                case .editGroup(let group):
                    NavigationStack { RoutingGroupEditor(controller: controller, draft: group, isNew: false) }
                case .editSubscription(let subscription):
                    SubscriptionEditor(controller: controller, subscription: subscription)
                case .share(let item):
                    NodeShareSheet(item: item)
                }
            }
            .alert(L10n.text("删除「{0}」？", actions.deletion?.name ?? ""), isPresented: Binding(
                get: { actions.deletion != nil },
                set: { if !$0 { actions.deletion = nil } }
            ), presenting: actions.deletion) { group in
                Button(L10n.text("删除"), role: .destructive) { delete(group) }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: { group in
                Text(group.subscription == nil ? L10n.text("组内节点会保留。") : L10n.text("将同时移除订阅中的节点。"))
            }
            .overlay(alignment: .bottom) {
                if let progress = actions.progress {
                    ProgressView(progress)
                        .padding(12)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8)
                }
            }
    }

    private func delete(_ group: NodeListGroup) {
        actions.progress = L10n.text("正在删除")
        Task {
            defer { actions.progress = nil }
            do {
                switch group.id {
                case .subscription(let id):
                    try await controller.manage("DELETE", "/v1/subscriptions/\(id.uuidString)")
                case .manual(let id):
                    var settings = controller.profile.globalRoutingSettings
                    settings.removeGroup(id)
                    try await controller.saveGlobalRouting(settings)
                case .ungrouped:
                    return
                }
                onDeletion()
            } catch { controller.message = error.localizedDescription }
        }
    }
}

private struct SubscriptionEditor: View {
    @ObservedObject var controller: VPNController
    let subscription: NodeSubscription
    @Environment(\.dismiss) private var dismiss
    @State private var name: String?
    @State private var link = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.text("名称"), text: Binding(get: { name ?? subscription.name }, set: { name = $0 }))
                        .accessibilityIdentifier("edit-subscription-name")
                    SecureField(L10n.text("替换订阅地址"), text: $link).bywayNoAutocapitalization().autocorrectionDisabled()
                    if let host = subscription.address.host { LabeledContent(L10n.text("订阅服务器"), value: host) }
                }
                .disabled(saving)
                if saving { ProgressView(L10n.text("正在保存订阅")) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(L10n.text("编辑订阅"))
            .bywayInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("保存"), action: save)
                        .disabled(saving || !controller.canManage ||
                                  (name == nil && link.isEmpty) || name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        var body: [String: String] = [:]
        if let name { body["name"] = name }
        if !link.isEmpty { body["link"] = link }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await controller.manage("PATCH", "/v1/subscriptions/\(subscription.id.uuidString)", body: body)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
