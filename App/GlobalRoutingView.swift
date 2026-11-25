import SwiftUI

struct GlobalRoutingView: View {
    @ObservedObject var controller: VPNController
    @State private var error: String?

    private var settings: GlobalRouting { controller.profile.globalRoutingSettings }

    var body: some View {
        Form {
            Section {
                Picker("选择模式", selection: Binding(
                    get: { settings.mode },
                    set: { mode in update { $0.mode = mode } }
                )) {
                    ForEach(RoutingMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("global-routing-mode")
                .disabled(controller.busy)
            } header: {
                Text("路由模式")
            } footer: {
                Text(modeDescription)
            }

            if let network = controller.routingNetwork, settings.mode == .scene {
                Section("当前场景") {
                    LabeledContent(network.title, value: controller.effectiveRouting.mode.title)
                    let group = settings.groups.first { $0.id == controller.effectiveRouting.groupID }
                    LabeledContent("生效节点组", value: group?.name ?? "全部节点")
                }
            }

            Section {
                GroupPicker(groups: settings.groups, selection: Binding(
                    get: { settings.groupID },
                    set: { groupID in update { $0.groupID = groupID } }
                ))
                .disabled(controller.busy || settings.groups.isEmpty)
                Toggle("故障切换", isOn: Binding(
                    get: { settings.fallback },
                    set: { enabled in update { $0.fallback = enabled } }
                ))
                .accessibilityIdentifier("routing-fallback")
                .disabled(controller.busy)
            } header: {
                Text("代理出口")
            } footer: {
                Text("当前节点连续测试失败时，切换到同组内已验证可用的节点。")
            }

            Section {
                NavigationLink {
                    RoutingGroupsView(controller: controller)
                } label: {
                    Label("管理节点组", systemImage: "square.stack")
                }
                NavigationLink {
                    RoutingScenesView(controller: controller)
                } label: {
                    Label("设置场景", systemImage: "network")
                }
            }
        }
        .navigationTitle("全局路由")
        .navigationBarTitleDisplayMode(.inline)
        .routingError($error)
    }

    private var modeDescription: String {
        switch settings.mode {
        case .rules: "使用当前分流规则。"
        case .proxy: "将进入隧道的流量转发到代理节点。"
        case .direct: "将进入隧道的流量直接转发。"
        case .scene: "根据当前网络选择路由模式和节点组。"
        }
    }

    private func update(_ change: (inout GlobalRouting) -> Void) {
        var next = settings
        change(&next)
        Task {
            do { try await controller.saveGlobalRouting(next) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct GroupPicker: View {
    let groups: [RoutingGroup]
    @Binding var selection: UUID?

    var body: some View {
        Picker("节点组", selection: $selection) {
            Text("全部节点").tag(UUID?.none)
            ForEach(groups) { Text($0.name).tag(Optional($0.id)) }
        }
    }
}

private struct RoutingGroupsView: View {
    @ObservedObject var controller: VPNController
    @State private var groupActions = NodeGroupActions()

    var body: some View {
        List {
            ForEach(NodeListGroup.all(in: controller.profile).filter { $0.id != .ungrouped }) { group in
                NavigationLink {
                    NodeGroupDetail(controller: controller, id: group.id)
                } label: {
                    LabeledContent(group.name, value: "\(group.nodes.count) 个节点")
                }
                .contextMenu {
                    NodeGroupMenuItems(controller: controller, group: group, actions: $groupActions)
                }
            }
            NavigationLink {
                RoutingGroupEditor(controller: controller, draft: RoutingGroup(name: ""), isNew: true)
            } label: {
                Label("新建节点组", systemImage: "plus")
            }
            .disabled(controller.profile.nodes.isEmpty || controller.busy)
            if controller.profile.nodes.isEmpty {
                Text("添加节点后可创建节点组。").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("节点组")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(NodeGroupActionPresenter(controller: controller, actions: $groupActions))
    }
}

struct RoutingGroupEditor: View {
    @ObservedObject var controller: VPNController
    @State var draft: RoutingGroup
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        Form {
            TextField("节点组名称", text: $draft.name)
            Section("成员") {
                ForEach(controller.profile.nodes) { node in
                    Toggle(node.name, isOn: Binding(
                        get: { draft.nodeIDs.contains(node.id) },
                        set: { included in
                            if included { draft.nodeIDs.append(node.id) }
                            else { draft.nodeIDs.removeAll { $0 == node.id } }
                        }
                    ))
                }
            }
        }
        .disabled(saving)
        .navigationTitle(isNew ? "新建节点组" : "编辑节点组")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isNew {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || draft.nodeIDs.isEmpty || saving || !controller.canManage)
            }
        }
        .routingError($error)
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        var settings = controller.profile.globalRoutingSettings
        if isNew {
            settings.groups.append(draft)
        } else {
            guard let index = settings.groups.firstIndex(where: { $0.id == draft.id }) else {
                error = "节点组已移除"
                return
            }
            settings.groups[index] = draft
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await controller.saveGlobalRouting(settings)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct RoutingScenesView: View {
    @ObservedObject var controller: VPNController

    var body: some View {
        List {
            Section {
                ForEach(RoutingNetwork.allCases) { network in
                    let scene = controller.profile.globalRoutingSettings.scenes.first { $0.network == network }
                    NavigationLink {
                        RoutingSceneEditor(controller: controller, draft: scene ?? RoutingScene(network: network),
                                           enabled: scene != nil)
                    } label: {
                        LabeledContent(network.title, value: scene?.mode.title ?? "未设置")
                    }
                }
            } footer: {
                Text("未设专属场景的网络使用「其他网络」，也可沿用按配置分流。")
            }
        }
        .navigationTitle("场景")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RoutingSceneEditor: View {
    @ObservedObject var controller: VPNController
    @State var draft: RoutingScene
    @State var enabled: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        Form {
            Toggle("启用场景", isOn: $enabled)
            if enabled {
                Picker("路由模式", selection: $draft.mode) {
                    ForEach(RoutingMode.allCases.filter { $0 != .scene }) { Text($0.title).tag($0) }
                }
                GroupPicker(groups: controller.profile.globalRoutingSettings.groups, selection: $draft.groupID)
            }
        }
        .navigationTitle(draft.network.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }.disabled(controller.busy)
            }
        }
        .routingError($error)
    }

    private func save() {
        var settings = controller.profile.globalRoutingSettings
        settings.scenes.removeAll { $0.network == draft.network }
        if enabled { settings.scenes.append(draft) }
        Task {
            do {
                try await controller.saveGlobalRouting(settings)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private extension View {
    func routingError(_ message: Binding<String?>) -> some View {
        alert("无法保存路由设置", isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("好", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
