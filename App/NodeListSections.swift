import SwiftUI

enum NodeListTarget: Hashable {
    case node(UUID)
    case group(NodeListGroup.ID)
}

struct NodeBatchTestButton: View {
    @ObservedObject var controller: VPNController
    var compact = false
    var nodeIDs: Set<UUID>?
    @State private var startedHere = false

    private var canStop: Bool { controller.batchProgress != nil && (nodeIDs == nil || startedHere) }

    var body: some View {
        Button {
            if controller.batchProgress == nil { startedHere = true }
            controller.toggleBatchTest(only: nodeIDs)
        } label: {
            if canStop, let progress = controller.batchProgress {
                Label(controller.stoppingBatch ? "正在停止" : "停止测试 · \(progress.completed)/\(progress.total)",
                      systemImage: "stop.circle")
            } else {
                Label(compact ? "测试全部" : "测试全部节点延迟", systemImage: "waveform.path")
                    .accessibilityLabel(nodeIDs == nil ? "测试全部节点延迟" : "测试本次导入的节点")
            }
        }
        .disabled(canStop ? controller.stoppingBatch : !controller.canTest)
        .onChange(of: controller.batchProgress == nil) { _, finished in
            if finished { startedHere = false }
        }
        .accessibilityIdentifier("test-all-nodes")
    }
}

struct NodeListSections: View {
    @ObservedObject var controller: VPNController
    @Binding var nodeActions: NodeActionPresentation
    @Binding var groupActions: NodeGroupActions
    var search = ""
    var selection: NodeListTarget?
    var openNode: ((UUID) -> Void)?
    let openGroup: (NodeListGroup.ID) -> Void

    @AppStorage("expanded-home-node-groups") private var storedExpandedGroups = ""

    private var expandedGroups: Set<String> { Set(storedExpandedGroups.split(separator: "|").map(String.init)) }
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private struct VisibleGroup: Identifiable {
        let group: NodeListGroup
        let nodes: [ProxyNode]
        var id: NodeListGroup.ID { group.id }
    }

    private var visibleGroups: [VisibleGroup] {
        let query = query
        return NodeListGroup.all(in: controller.profile).compactMap { group in
            if query.isEmpty || group.name.localizedStandardContains(query) {
                return VisibleGroup(group: group, nodes: group.nodes)
            }
            let matching = group.nodes.filter { node in
                [node.name, node.host, node.protocolName].contains { $0.localizedStandardContains(query) }
            }
            return matching.isEmpty ? nil : VisibleGroup(group: group, nodes: matching)
        }
    }

    var body: some View {
        let groups = visibleGroups
        let isSearching = !query.isEmpty
        ForEach(groups) { item in
            let expanded = isSearching || expandedGroups.contains(item.id.storageKey)
            Section {
                groupRow(item.group, count: item.nodes.count, expanded: expanded, isSearching: isSearching)
                if expanded {
                    ForEach(item.nodes) { node in nodeRow(node) }
                    if item.nodes.isEmpty { Text("此组暂无节点").foregroundStyle(.secondary) }
                }
            }
        }
        if isSearching && groups.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    private func groupRow(_ group: NodeListGroup, count: Int, expanded: Bool, isSearching: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                var groups = expandedGroups
                if expanded { groups.remove(group.id.storageKey) }
                else { groups.insert(group.id.storageKey) }
                withAnimation { storedExpandedGroups = groups.sorted().joined(separator: "|") }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 13)
                        .accessibilityHidden(true)
                    Text(group.name).font(.headline).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text("\(count) 个节点").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSearching)
            .accessibilityValue(expanded ? "已展开" : "已折叠")
            .accessibilityIdentifier("node-group-\(group.id.storageKey)")

            Button { openGroup(group.id) } label: {
                Image(systemName: "info.circle")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(group.name)详情")
            .accessibilityIdentifier("node-group-info-\(group.id.storageKey)")
        }
        .contextMenu { NodeGroupMenuItems(controller: controller, group: group, actions: $groupActions) }
        .listRowBackground(selection == .group(group.id) ? Color.bywayAccent.opacity(0.12) : nil)
    }

    private func nodeRow(_ node: ProxyNode) -> some View {
        let active = controller.activeNode?.id == node.id
        let selected = selection == .node(node.id)
        return HStack(spacing: 12) {
            if let openNode {
                Button { openNode(node.id) } label: { workspaceNodeLabel(node, active: active) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("ipad-node-\(node.id.uuidString.lowercased())")
            } else {
                NavigationLink {
                    NodeDetailsView(controller: controller, id: node.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: active ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(node.name).foregroundStyle(.primary)
                            Text(phoneNodeStatus(node)).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(active ? .isSelected : [])
            }
            if controller.testingNodeID == node.id {
                ProgressView()
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("正在测试\(node.name)")
            } else {
                Button { Task { await controller.probe(node) } } label: {
                    Image(systemName: "waveform.path").frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("测试\(node.name)的延迟")
                .disabled(!controller.canTest)
            }
        }
        .contextMenu { NodeMenuItems(controller: controller, node: node, actions: $nodeActions) }
        .listRowBackground(selected ? Color.bywayAccent.opacity(0.12) : nil)
        .swipeActions {
            if controller.canManage {
                Button(role: .destructive) {
                    Task {
                        do { try await controller.manage("DELETE", "/v1/nodes/" + node.id.uuidString) }
                        catch { controller.message = error.localizedDescription }
                    }
                } label: { Label("移除", systemImage: "trash") }
            }
        }
    }

    private func workspaceNodeLabel(_ node: ProxyNode, active: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(2)
                Text(node.protocolName.uppercased()).font(.caption).foregroundStyle(.secondary)
                if active {
                    Text(controller.connected && !controller.routesDirectly ? "使用中" : "已选出口")
                        .font(.caption).foregroundStyle(Color.bywayAccent)
                }
            }
            Spacer(minLength: 4)
            if let measurement = controller.probes[node.id] {
                switch measurement {
                case .succeeded(let probe):
                    Text("\(probe.latencyMS) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .fixedSize()
                case .failed:
                    Image(systemName: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("测试未通过")
                }
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func phoneNodeStatus(_ node: ProxyNode) -> String {
        switch controller.probes[node.id] {
        case .succeeded(let probe): "\(probe.latencyMS) ms · \(probe.exitIP)"
        case .failed: "连接测试未通过"
        case nil: node.host
        }
    }
}
