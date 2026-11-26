import SwiftUI

enum NodeListTarget: Hashable {
    case node(UUID)
    case group(NodeListGroup.ID)
}

private enum NodeListLayout {
    static let disclosureWidth: CGFloat = 13
    static let disclosureSpacing: CGFloat = 10

    #if os(macOS)
    static let groupHeight: CGFloat = 24
    static let nodeHeight: CGFloat = 30
    static let actionSize: CGFloat = 22
    static let groupFont = Font.system(size: 11, weight: .semibold)
    static let countFont = Font.system(size: 10.5)
    static let nodeFont = Font.system(size: 13)
    static let metadataFont = Font.system(size: 10.5)
    static let nodeLineLimit: Int? = 1
    static let groupTitleLineLimit: Int? = 1
    static let measurementAlignment: VerticalAlignment = .center
    #else
    static let groupHeight: CGFloat = 44
    static let nodeHeight: CGFloat = 44
    static let actionSize: CGFloat = 44
    static let groupFont = Font.headline
    static let countFont = Font.subheadline
    static let nodeFont = Font.subheadline.weight(.semibold)
    static let metadataFont = Font.caption
    static let nodeLineLimit: Int? = 2
    static let groupTitleLineLimit: Int? = nil
    static let measurementAlignment: VerticalAlignment = .firstTextBaseline
    #endif
}

private struct NodeListRowAppearance: ViewModifier {
    let selected: Bool
    var isGroup = false

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(
                RoundedRectangle(cornerRadius: BywayStyle.Radius.control, style: .continuous)
                    .fill(fill)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
            )
        #else
        content.listRowBackground(selected ? Color.bywayAccent.opacity(0.12) : nil)
        #endif
    }

    private var fill: Color {
        if selected { return Color.bywayAccent.opacity(0.16) }
        if isGroup { return Color.primary.opacity(0.03) }
        return .clear
    }
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
                Label(controller.stoppingBatch ? L10n.text("正在停止") : L10n.text("停止测试 · {0}/{1}", progress.completed, progress.total),
                      systemImage: "stop.circle")
            } else {
                Label(compact ? L10n.text("测试全部") : L10n.text("测试全部节点延迟"), systemImage: "waveform.path")
                    .accessibilityLabel(nodeIDs == nil ? L10n.text("测试全部节点延迟") : L10n.text("测试本次导入的节点"))
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
    #if os(macOS)
    @Environment(\.colorScheme) private var colorScheme
    #endif
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
                    if item.nodes.isEmpty {
                        Text(L10n.text("此组暂无节点"))
                            .foregroundStyle(.secondary)
                            #if os(macOS)
                            .font(NodeListLayout.metadataFont)
                            .padding(.leading, NodeListLayout.disclosureWidth + NodeListLayout.disclosureSpacing)
                            .frame(minHeight: NodeListLayout.nodeHeight)
                            .modifier(NodeListRowAppearance(selected: false))
                            #endif
                    }
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
                HStack(spacing: NodeListLayout.disclosureSpacing) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: NodeListLayout.disclosureWidth)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                    Text(group.name)
                        .font(NodeListLayout.groupFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(NodeListLayout.groupTitleLineLimit)
                        #if os(macOS)
                        .help(group.name)
                        #endif
                    Spacer(minLength: 8)
                    Text("\(count)")
                        .font(NodeListLayout.countFont)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        #if os(macOS)
                        .fixedSize()
                        #endif
                }
                .frame(minHeight: NodeListLayout.groupHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSearching)
            .accessibilityValue(expanded ? L10n.text("已展开") : L10n.text("已折叠"))
            .accessibilityIdentifier("node-group-\(group.id.storageKey)")

            Button { openGroup(group.id) } label: {
                Image(systemName: "info.circle")
                    .frame(width: NodeListLayout.actionSize, height: NodeListLayout.actionSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            #if os(macOS)
            .foregroundStyle(.secondary)
            #endif
            .accessibilityLabel(L10n.text("{0}详情", group.name))
            .accessibilityIdentifier("node-group-info-\(group.id.storageKey)")
        }
        .contextMenu { NodeGroupMenuItems(controller: controller, group: group, actions: $groupActions) }
        .modifier(NodeListRowAppearance(selected: selection == .group(group.id), isGroup: true))
    }

    private func nodeRow(_ node: ProxyNode) -> some View {
        let active = controller.activeNode?.id == node.id
        let selected = selection == .node(node.id)
        return HStack(spacing: 8) {
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
                    #if os(macOS)
                    .controlSize(.small)
                    #endif
                    .frame(minWidth: NodeListLayout.actionSize, minHeight: NodeListLayout.actionSize)
                    .accessibilityLabel(L10n.text("正在测试{0}", node.name))
            } else {
                Button { Task { await controller.probe(node) } } label: {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 11))
                        .frame(minWidth: NodeListLayout.actionSize, minHeight: NodeListLayout.actionSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                #if os(macOS)
                .foregroundStyle(.secondary)
                #endif
                .accessibilityLabel(L10n.text("测试{0}的延迟", node.name))
                .disabled(!controller.canTest)
            }
        }
        .contextMenu { NodeMenuItems(controller: controller, node: node, actions: $nodeActions) }
        .modifier(NodeListRowAppearance(selected: selected))
        .swipeActions {
            if controller.canManage {
                Button(role: .destructive) {
                    Task {
                        do { try await controller.manage("DELETE", "/v1/nodes/" + node.id.uuidString) }
                        catch { controller.message = error.localizedDescription }
                    }
                } label: { Label(L10n.text("移除"), systemImage: "trash") }
            }
        }
    }

    private func workspaceNodeLabel(_ node: ProxyNode, active: Bool) -> some View {
        HStack(alignment: NodeListLayout.measurementAlignment, spacing: 6) {
            #if os(macOS)
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(active ? Color.bywayBrand : Color.secondary.opacity(0.45))
                .accessibilityHidden(true)
            #endif
            #if os(macOS)
            Text(node.name)
                .font(NodeListLayout.nodeFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
                .help(node.name)
            workspaceNodeMetadata(node, active: active)
            #else
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name).font(NodeListLayout.nodeFont).foregroundStyle(.primary)
                    .lineLimit(NodeListLayout.nodeLineLimit)
                workspaceNodeMetadata(node, active: active)
            }
            #endif
            Spacer(minLength: 4)
            if let measurement = controller.probes[node.id] {
                switch measurement {
                case .succeeded(let probe):
                    Text("\(probe.latencyMS) ms")
                        .font(NodeListLayout.metadataFont.monospacedDigit()).foregroundStyle(.secondary)
                        .fixedSize()
                case .failed:
                    Image(systemName: "exclamationmark.circle")
                        .font(NodeListLayout.metadataFont).foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.text("测试未通过"))
                }
            }
        }
        .frame(minHeight: NodeListLayout.nodeHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func workspaceNodeMetadata(_ node: ProxyNode, active: Bool) -> some View {
        let protocolName = Text(node.protocolName.uppercased())
            .font(NodeListLayout.metadataFont).foregroundStyle(active ? Color.primary : .secondary)
        let status = Text(controller.connected && !controller.routesDirectly ? L10n.text("使用中") : L10n.text("已选出口"))
            .font(NodeListLayout.metadataFont)
        #if os(macOS)
        let statusColor = colorScheme == .dark ? Color(red: 0.39, green: 0.78, blue: 0.70) : .bywayAccent
        return HStack(spacing: 6) {
            protocolName
            if active { status.foregroundStyle(statusColor) }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(node.protocolName)
        #else
        return Group {
            protocolName
            if active { status.foregroundStyle(Color.bywayAccent) }
        }
        #endif
    }

    private func phoneNodeStatus(_ node: ProxyNode) -> String {
        switch controller.probes[node.id] {
        case .succeeded(let probe): "\(probe.latencyMS) ms · \(probe.exitIP)"
        case .failed: L10n.text("连接测试未通过")
        case nil: node.host
        }
    }
}
