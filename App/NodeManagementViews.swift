import CoreImage.CIFilterBuiltins
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import Vision

struct NodeEditor: View {
    @ObservedObject var controller: VPNController
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var progress: String?
    @State private var busy = false
    @State private var picker: PhotosPickerItem?
    @State private var fileImporter = false
    @State private var parts = NodeShareParts()
    @State private var path: [Destination] = []
    @State private var result: ImportResult?

    private enum Destination: Hashable { case scanner }

    private struct ImportResult: Decodable {
        let nodeIDs: [UUID]
        let added: Int?
        let skipped: Int?
        let name: String?

        var title: String {
            if name != nil { return "订阅已保存" }
            guard let added else { return "导入完成" }
            return added == 0 ? "已有 \(nodeIDs.count) 个节点" : "已添加 \(added) 个节点"
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let result { importSummary(result) }
                else { importForm }
            }
            .navigationTitle(result == nil ? "添加节点" : "导入结果")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Destination.self) { _ in NodeQRScanner(save: importCode) }
            .toolbar {
                if result == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if result != nil {
                        Button("完成") { dismiss() }
                    } else {
                        Button("导入") { submit(text) }
                            .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .fileImporter(isPresented: $fileImporter, allowedContentTypes: [.plainText, .json, .data]) { result in
                do { submit(try readImportFile(result.get(), limit: NodeImport.maxBytes)) }
                catch { self.error = error.localizedDescription }
            }
            .onChange(of: picker) { _, item in
                guard let item else { return }
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw BywayError.message("无法读取图片")
                        }
                        let code = try await Task.detached {
                            let scan = VNDetectBarcodesRequest()
                            scan.symbologies = [.qr]
                            try VNImageRequestHandler(data: data).perform([scan])
                            guard let text = scan.results?.first?.payloadStringValue else {
                                throw BywayError.message("图片中没有可读取的二维码")
                            }
                            return text
                        }.value
                        _ = try await importCode(code)
                    } catch { self.error = error.localizedDescription }
                    picker = nil
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private var importForm: some View {
        Form {
            Section {
                NavigationLink(value: Destination.scanner) { Label("扫码添加", systemImage: "qrcode.viewfinder") }
                    .accessibilityIdentifier("scan-node")
                PhotosPicker(selection: $picker, matching: .images) {
                    Label("读取二维码图片", systemImage: "photo")
                }
                Button { fileImporter = true } label: { Label("导入节点文件", systemImage: "document") }
            }
            .disabled(busy)
            Section {
                TextField("粘贴节点、订阅链接或节点列表", text: $text, axis: .vertical)
                    .lineLimit(3...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("node-link")
            } footer: {
                Text("支持 VLESS、VMess、Shadowsocks、SOCKS5、HTTPS 订阅和 Byway 分享码。")
            }
            if let progress { Text(progress).foregroundStyle(.secondary) }
            if busy { ProgressView("正在导入") }
            if let error { Text(error).foregroundStyle(.red) }
        }
    }

    private func importSummary(_ result: ImportResult) -> some View {
        let ids = Set(result.nodeIDs)
        let nodes = controller.profile.nodes.filter { ids.contains($0.id) }
        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(result.title, systemImage: "checkmark.circle.fill").font(.headline)
                    if let name = result.name {
                        Text("\(name) · \(result.nodeIDs.count) 个节点").foregroundStyle(.secondary)
                    }
                    if let added = result.added, added > 0, added < result.nodeIDs.count {
                        Text("已有 \(result.nodeIDs.count - added) 个节点").foregroundStyle(.secondary)
                    }
                    if let skipped = result.skipped, skipped > 0 {
                        Text("已跳过 \(skipped) 条无法导入的记录").foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("node-import-result")
            }
            if !nodes.isEmpty {
                Section {
                    NodeBatchTestButton(controller: controller, compact: true, nodeIDs: ids)
                    ForEach(nodes) { node in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(node.name)
                                Text(testStatus(node)).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if controller.activeNode?.id == node.id {
                                Label("已选为出口", systemImage: "checkmark.circle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(Color.bywayAccent)
                                    .accessibilityIdentifier("imported-node-current-\(node.id.uuidString.lowercased())")
                            } else {
                                Button("使用此节点") { Task { await controller.choose(node) } }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(!controller.canManage || !controller.canSelectNode(node))
                                    .accessibilityIdentifier("use-imported-node-\(node.id.uuidString.lowercased())")
                            }
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func testStatus(_ node: ProxyNode) -> String {
        if controller.testingNodeID == node.id { return "正在测试" }
        switch controller.probes[node.id] {
        case .succeeded(let probe): return "\(probe.latencyMS) ms"
        case .failed: return "连接测试未通过"
        case nil: return "待测试"
        }
    }

    private func submit(_ value: String) {
        guard !busy else { return }
        Task {
            do { _ = try await importCode(value) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func importCode(_ code: String) async throws -> String? {
        guard !busy, result == nil else { return nil }
        error = nil
        guard let complete = try parts.accept(code) else {
            progress = parts.progress
            return progress
        }
        busy = true
        defer { busy = false }
        let response = try await controller.manage("POST", "/v1/import", body: ["text": complete])
        result = (try? JSONDecoder().decode(ImportResult.self, from: response))
            ?? ImportResult(nodeIDs: [], added: nil, skipped: nil, name: nil)
        path.removeAll()
        return nil
    }
}

struct SubscriptionsView: View {
    @ObservedObject var controller: VPNController
    @State private var importing = false
    @State private var groupActions = NodeGroupActions()

    var body: some View {
        List {
            ForEach(NodeListGroup.all(in: controller.profile).filter { $0.subscription != nil }) { group in
                NavigationLink {
                    NodeGroupDetail(controller: controller, id: group.id)
                } label: {
                    LabeledContent(group.name, value: "\(group.nodes.count) 个节点")
                }
                .contextMenu {
                    NodeGroupMenuItems(controller: controller, group: group, actions: $groupActions)
                }
            }
            Button { importing = true } label: { Label("添加订阅", systemImage: "plus") }
        }
        .navigationTitle("订阅")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $importing) { NodeEditor(controller: controller) }
        .modifier(NodeGroupActionPresenter(controller: controller, actions: $groupActions))
    }
}

struct NodeDetailsView: View {
    @ObservedObject var controller: VPNController
    let id: UUID
    var workspaceStyle = false
    var onDeletion: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var nodeActions = NodeActionPresentation()

    private var node: ProxyNode? { controller.profile.nodes.first { $0.id == id } }

    var body: some View {
        Group {
            if workspaceStyle, let node {
                workspaceDetails(node)
            } else {
                Form {
                    if let node {
                        Section {
                            LabeledContent("节点名称", value: node.name)
                            LabeledContent("服务器", value: "\(node.host):\(node.port)")
                            LabeledContent("协议", value: node.protocolName)
                        }
                        Section {
                            if controller.activeNode?.id == id {
                                Label("当前使用", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            } else {
                                useButton(node)
                            }
                            testButton(node)
                            switch controller.probes[id] {
                            case .succeeded(let probe):
                                LabeledContent("延迟", value: "\(probe.latencyMS) ms")
                                LabeledContent("出口 IP", value: probe.exitIP)
                            case .failed:
                                Text("连接测试未通过").foregroundStyle(.secondary)
                            case nil:
                                EmptyView()
                            }
                        }
                    } else {
                        ContentUnavailableView("节点已移除", systemImage: "server.rack")
                    }
                    if nodeActions.isDeleting { ProgressView("正在删除节点") }
                }
            }
        }
        .navigationTitle("节点详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let node {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NodeMenuItems(controller: controller, node: node, actions: $nodeActions)
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    }
                    .accessibilityIdentifier("node-more")
                    .disabled(nodeActions.isDeleting)
                }
            }
        }
        .modifier(NodeActionPresenter(controller: controller, actions: $nodeActions, onDeletion: {
            if let onDeletion { onDeletion() }
            else { dismiss() }
        }))
    }

    private func workspaceDetails(_ node: ProxyNode) -> some View {
        let groups = NodeListGroup.all(in: controller.profile)
            .filter { $0.nodes.contains { $0.id == node.id } }.map(\.name)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(node.name).font(.largeTitle.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("ipad-node-detail-name")
                    Text(node.protocolName.uppercased()).font(.subheadline).foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { workspaceActions(node) }
                    VStack(alignment: .leading, spacing: 10) { workspaceActions(node) }
                }
                let values = probeSummary
                HStack(spacing: 0) {
                    nodeMetric("最近延迟", value: values.latency)
                    Divider()
                    nodeMetric("出口 IP", value: values.exitIP)
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))

                VStack(spacing: 12) {
                    LabeledContent("服务器", value: node.host)
                    Divider()
                    LabeledContent("端口", value: node.port.formatted(.number.grouping(.never)))
                    if !groups.isEmpty {
                        Divider()
                        LabeledContent("所在组", value: groups.joined(separator: "、"))
                    }
                }
                .font(.subheadline)
                if nodeActions.isDeleting { ProgressView("正在删除节点") }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(22)
        }
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder private func workspaceActions(_ node: ProxyNode) -> some View {
        if controller.activeNode?.id == id {
            Label(controller.connected && !controller.routesDirectly ? "当前使用" : "已选为出口",
                  systemImage: "checkmark.circle.fill").foregroundStyle(Color.bywayAccent)
        } else {
            useButton(node).buttonStyle(.borderedProminent)
        }
        testButton(node).buttonStyle(.bordered)
    }

    private func useButton(_ node: ProxyNode) -> some View {
        Button("使用此节点") { Task { await controller.choose(node) } }
            .disabled(nodeActions.isDeleting || !controller.canManage || !controller.canSelectNode(node))
    }

    private func testButton(_ node: ProxyNode) -> some View {
        Button { Task { await controller.probe(node) } } label: {
            if controller.testingNodeID == id { ProgressView("正在测试延迟") }
            else { Label("测试延迟", systemImage: "waveform.path") }
        }
        .disabled(nodeActions.isDeleting || !controller.canTest)
    }

    private var probeSummary: (latency: String, exitIP: String) {
        switch controller.probes[id] {
        case .succeeded(let probe): ("\(probe.latencyMS) ms", probe.exitIP)
        case .failed: ("测试未通过", "—")
        case nil: ("未测试", "—")
        }
    }

    private func nodeMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .accessibilityElement(children: .combine)
    }
}

struct NodeActionPresentation {
    enum Sheet: Identifiable {
        case add, edit(ProxyNode), share(NodeShareItem)

        var id: String {
            switch self {
            case .add: "add"
            case .edit: "edit"
            case .share: "share"
            }
        }
    }

    var sheet: Sheet?
    var deletion: ProxyNode?
    var isDeleting = false
}

struct NodeMenuItems: View {
    @ObservedObject var controller: VPNController
    let node: ProxyNode
    @Binding var actions: NodeActionPresentation

    private var canManage: Bool { controller.canManage && !actions.isDeleting }

    var body: some View {
        Button("添加节点", systemImage: "plus") { actions.sheet = .add }
            .disabled(!canManage)
        Button("编辑节点", systemImage: "pencil") { actions.sheet = .edit(node) }
            .disabled(!canManage)
        Button("分享二维码", systemImage: "qrcode") {
            do { actions.sheet = .share(NodeShareItem(link: try node.shareLink())) }
            catch { controller.message = error.localizedDescription }
        }
        Divider()
        Button("删除节点", systemImage: "trash", role: .destructive) { actions.deletion = node }
            .disabled(!canManage)
    }
}

struct NodeActionPresenter: ViewModifier {
    @ObservedObject var controller: VPNController
    @Binding var actions: NodeActionPresentation
    var onDeletion: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.sheet) { item in
                switch item {
                case .add: NodeEditor(controller: controller)
                case .edit(let node): EditNodeView(controller: controller, node: node)
                case .share(let share): NodeShareSheet(item: share)
                }
            }
            .alert("删除节点？", isPresented: Binding(
                get: { actions.deletion != nil },
                set: { if !$0 { actions.deletion = nil } }
            ), presenting: actions.deletion) { node in
                Button("删除节点", role: .destructive) { delete(node) }
                Button("取消", role: .cancel) {}
            } message: { node in
                if controller.connected && controller.profile.nodes.count == 1 {
                    Text("删除「\(node.name)」后，VPN 将断开。")
                } else {
                    Text("将从 Byway 中移除「\(node.name)」。")
                }
            }
    }

    private func delete(_ node: ProxyNode) {
        actions.isDeleting = true
        Task {
            defer { actions.isDeleting = false }
            do {
                try await controller.manage("DELETE", "/v1/nodes/" + node.id.uuidString)
                onDeletion()
            } catch { controller.message = error.localizedDescription }
        }
    }
}

private struct EditNodeView: View {
    @ObservedObject var controller: VPNController
    let node: ProxyNode
    @Environment(\.dismiss) private var dismiss
    @State private var name: String?
    @State private var link = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("节点名称", text: Binding(get: { name ?? node.name }, set: { name = $0 }))
                        .accessibilityIdentifier("edit-node-name")
                    SecureField("替换连接链接", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .disabled(saving || !controller.canManage)
                if let error { Text(error).foregroundStyle(.red) }
                if saving { ProgressView("正在保存节点") }
            }
            .navigationTitle("编辑节点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(saving || !controller.canManage || changes.isEmpty ||
                                  name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private var changes: [String: String] {
        var body: [String: String] = [:]
        if let name, name != node.name { body["name"] = name }
        if !link.isEmpty { body["link"] = link }
        return body
    }

    private func save() {
        let body = changes
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await controller.manage("PATCH", "/v1/nodes/" + node.id.uuidString, body: body)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct NodeShareItem: Identifiable {
    let id = UUID()
    let link: String
}

struct NodeShareSheet: View {
    let item: NodeShareItem
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var copied = false
    private let context = CIContext()

    var body: some View {
        let parts = NodeShare.parts(item.link)
        NavigationStack {
            List {
                Section {
                    if let image = qr(parts[index]) {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                            .frame(maxWidth: 320)
                            .padding(12)
                            .background(.white)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("分享二维码")
                        if parts.count > 1 {
                            Stepper("第 \(index + 1) / \(parts.count) 张", value: $index, in: 0...parts.count - 1)
                        }
                    }
                }
                Section {
                    Button(copied ? "已复制" : "复制分享链接") {
                        UIPasteboard.general.string = item.link
                        copied = true
                    }
                    ShareLink(item: item.link) { Label("分享链接", systemImage: "square.and.arrow.up") }
                }
            }
            .navigationTitle("分享")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage, let image = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
