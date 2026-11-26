import CoreImage.CIFilterBuiltins
#if os(iOS)
import PhotosUI
#endif
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
    #if os(iOS)
    @State private var picker: PhotosPickerItem?
    #else
    @State private var photoImporter = false
    #endif
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
            if name != nil { return L10n.text("订阅已保存") }
            guard let added else { return L10n.text("导入完成") }
            return added == 0 ? L10n.text("已有 {0} 个节点", nodeIDs.count) : L10n.text("已添加 {0} 个节点", added)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let result { importSummary(result) }
                else { importForm }
            }
            .navigationTitle(result == nil ? L10n.text("添加节点") : L10n.text("导入结果"))
            .bywayInlineTitle()
            .navigationDestination(for: Destination.self) { _ in NodeQRScanner(save: importCode) }
            .toolbar {
                if result == nil {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { dismiss() }.disabled(busy) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if result != nil {
                        Button(L10n.text("完成")) { dismiss() }
                    } else {
                        Button(L10n.text("导入")) { submit(text) }
                            .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .fileImporter(isPresented: $fileImporter, allowedContentTypes: [.plainText, .json, .data]) { result in
                do { submit(try readImportFile(result.get(), limit: NodeImport.maxBytes)) }
                catch { self.error = error.localizedDescription }
            }
            #if os(iOS)
            .onChange(of: picker) { _, item in
                guard let item else { return }
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw BywayError.message(L10n.text("无法读取图片"))
                        }
                        _ = try await importCode(try await Self.code(in: data))
                    } catch { self.error = error.localizedDescription }
                    picker = nil
                }
            }
            #else
            .fileImporter(isPresented: $photoImporter, allowedContentTypes: [.image]) { result in
                do { _ = try awaitImportImage(result.get()) }
                catch { self.error = error.localizedDescription }
            }
            #endif
        }
        .interactiveDismissDisabled(busy)
    }

    private var importForm: some View {
        Form {
            Section {
                NavigationLink(value: Destination.scanner) { Label(L10n.text("扫码添加"), systemImage: "qrcode.viewfinder") }
                    .accessibilityIdentifier("scan-node")
                #if os(iOS)
                PhotosPicker(selection: $picker, matching: .images) {
                    Label(L10n.text("读取二维码图片"), systemImage: "photo")
                }
                #else
                Button { photoImporter = true } label: { Label(L10n.text("读取二维码图片"), systemImage: "photo") }
                #endif
                Button { fileImporter = true } label: { Label(L10n.text("导入节点文件"), systemImage: "document") }
            }
            .disabled(busy)
            Section {
                TextField(L10n.text("粘贴节点、订阅链接或节点列表"), text: $text, axis: .vertical)
                    .lineLimit(3...6)
                    .bywayNoAutocapitalization()
                    .autocorrectionDisabled()
                    .bywayKeyboardType(.url)
                    .accessibilityIdentifier("node-link")
            } footer: {
                Text(L10n.text("支持 VLESS、VMess、Shadowsocks、SOCKS5、HTTPS 订阅和 Byway 分享码。"))
            }
            if let progress { Text(progress).foregroundStyle(.secondary) }
            if busy { ProgressView(L10n.text("正在导入")) }
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
                        Text(L10n.text("{0} · {1} 个节点", name, result.nodeIDs.count)).foregroundStyle(.secondary)
                    }
                    if let added = result.added, added > 0, added < result.nodeIDs.count {
                        Text(L10n.text("已有 {0} 个节点", result.nodeIDs.count - added)).foregroundStyle(.secondary)
                    }
                    if let skipped = result.skipped, skipped > 0 {
                        Text(L10n.text("已跳过 {0} 条无法导入的记录", skipped)).foregroundStyle(.secondary)
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
                                Label(L10n.text("已选为出口"), systemImage: "checkmark.circle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(Color.bywayAccent)
                                    .accessibilityIdentifier("imported-node-current-\(node.id.uuidString.lowercased())")
                            } else {
                                Button(L10n.text("使用此节点")) { Task { await controller.choose(node) } }
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
        .bywayInsetGroupedList()
    }

    private func testStatus(_ node: ProxyNode) -> String {
        if controller.testingNodeID == node.id { return L10n.text("正在测试") }
        switch controller.probes[node.id] {
        case .succeeded(let probe): return "\(probe.latencyMS) ms"
        case .failed: return L10n.text("连接测试未通过")
        case nil: return L10n.text("待测试")
        }
    }

    private func submit(_ value: String) {
        guard !busy else { return }
        Task {
            do { _ = try await importCode(value) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func awaitImportImage(_ url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        let code = try Self.code(in: data)
        Task { _ = try? await importCode(code) }
        return code
    }

    private static func code(in data: Data) throws -> String {
        let scan = VNDetectBarcodesRequest()
        scan.symbologies = [.qr]
        try VNImageRequestHandler(data: data).perform([scan])
        guard let text = scan.results?.first?.payloadStringValue else {
            throw BywayError.message(L10n.text("图片中没有可读取的二维码"))
        }
        return text
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
                    LabeledContent(group.name, value: L10n.text("{0} 个节点", group.nodes.count))
                }
                .contextMenu {
                    NodeGroupMenuItems(controller: controller, group: group, actions: $groupActions)
                }
            }
            Button { importing = true } label: { Label(L10n.text("添加订阅"), systemImage: "plus") }
        }
        .navigationTitle(L10n.text("订阅"))
        .bywayInlineTitle()
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
                            LabeledContent(L10n.text("节点名称"), value: node.name)
                            LabeledContent(L10n.text("服务器"), value: "\(node.host):\(node.port)")
                            LabeledContent(L10n.text("协议"), value: node.protocolName)
                        }
                        Section {
                            if controller.activeNode?.id == id {
                                Label(L10n.text("当前使用"), systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            } else {
                                useButton(node)
                            }
                            testButton(node)
                            switch controller.probes[id] {
                            case .succeeded(let probe):
                                LabeledContent(L10n.text("延迟"), value: "\(probe.latencyMS) ms")
                                LabeledContent(L10n.text("出口 IP"), value: probe.exitIP)
                            case .failed:
                                Text(L10n.text("连接测试未通过")).foregroundStyle(.secondary)
                            case nil:
                                EmptyView()
                            }
                        }
                    } else {
                        ContentUnavailableView(L10n.text("节点已移除"), systemImage: "server.rack")
                    }
                    if nodeActions.isDeleting { ProgressView(L10n.text("正在删除节点")) }
                }
            }
        }
        .navigationTitle(L10n.text("节点详情"))
        .bywayInlineTitle()
        .toolbar {
            if let node {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        NodeMenuItems(controller: controller, node: node, actions: $nodeActions)
                    } label: {
                        Label(L10n.text("更多"), systemImage: "ellipsis.circle").labelStyle(.iconOnly)
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
                    nodeMetric(L10n.text("最近延迟"), value: values.latency)
                    Divider()
                    nodeMetric(L10n.text("出口 IP"), value: values.exitIP)
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(Color.bywayFill, in: RoundedRectangle(cornerRadius: 12))

                VStack(spacing: 12) {
                    LabeledContent(L10n.text("服务器"), value: node.host)
                    Divider()
                    LabeledContent(L10n.text("端口"), value: node.port.formatted(.number.grouping(.never)))
                    if !groups.isEmpty {
                        Divider()
                        LabeledContent(L10n.text("所在组"), value: groups.joined(separator: "、"))
                    }
                }
                .font(.subheadline)
                if nodeActions.isDeleting { ProgressView(L10n.text("正在删除节点")) }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(22)
        }
        .background(Color.bywayCardBackground)
    }

    @ViewBuilder private func workspaceActions(_ node: ProxyNode) -> some View {
        if controller.activeNode?.id == id {
            Label(controller.connected && !controller.routesDirectly ? L10n.text("当前使用") : L10n.text("已选为出口"),
                  systemImage: "checkmark.circle.fill").foregroundStyle(Color.bywayAccent)
        } else {
            useButton(node).buttonStyle(.borderedProminent)
        }
        testButton(node).buttonStyle(.bordered)
    }

    private func useButton(_ node: ProxyNode) -> some View {
        Button(L10n.text("使用此节点")) { Task { await controller.choose(node) } }
            .disabled(nodeActions.isDeleting || !controller.canManage || !controller.canSelectNode(node))
    }

    private func testButton(_ node: ProxyNode) -> some View {
        Button { Task { await controller.probe(node) } } label: {
            if controller.testingNodeID == id { ProgressView(L10n.text("正在测试延迟")) }
            else { Label(L10n.text("测试延迟"), systemImage: "waveform.path") }
        }
        .disabled(nodeActions.isDeleting || !controller.canTest)
    }

    private var probeSummary: (latency: String, exitIP: String) {
        switch controller.probes[id] {
        case .succeeded(let probe): ("\(probe.latencyMS) ms", probe.exitIP)
        case .failed: (L10n.text("测试未通过"), "—")
        case nil: (L10n.text("未测试"), "—")
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
        Button(L10n.text("添加节点"), systemImage: "plus") { actions.sheet = .add }
            .disabled(!canManage)
        Button(L10n.text("编辑节点"), systemImage: "pencil") { actions.sheet = .edit(node) }
            .disabled(!canManage)
        Button(L10n.text("分享二维码"), systemImage: "qrcode") {
            do { actions.sheet = .share(NodeShareItem(link: try node.shareLink())) }
            catch { controller.message = error.localizedDescription }
        }
        Divider()
        Button(L10n.text("删除节点"), systemImage: "trash", role: .destructive) { actions.deletion = node }
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
            .alert(L10n.text("删除节点？"), isPresented: Binding(
                get: { actions.deletion != nil },
                set: { if !$0 { actions.deletion = nil } }
            ), presenting: actions.deletion) { node in
                Button(L10n.text("删除节点"), role: .destructive) { delete(node) }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: { node in
                if controller.connected && controller.profile.nodes.count == 1 {
                    Text(L10n.text("删除「{0}」后，VPN 将断开。", node.name))
                } else {
                    Text(L10n.text("将从 Byway 中移除「{0}」。", node.name))
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
                    TextField(L10n.text("节点名称"), text: Binding(get: { name ?? node.name }, set: { name = $0 }))
                        .accessibilityIdentifier("edit-node-name")
                    SecureField(L10n.text("替换连接链接"), text: $link)
                        .bywayNoAutocapitalization().autocorrectionDisabled()
                }
                .disabled(saving || !controller.canManage)
                if let error { Text(error).foregroundStyle(.red) }
                if saving { ProgressView(L10n.text("正在保存节点")) }
            }
            .navigationTitle(L10n.text("编辑节点"))
            .bywayInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("保存"), action: save)
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
                        Image(bywayImage: image).interpolation(.none).resizable().scaledToFit()
                            .frame(maxWidth: 320)
                            .padding(12)
                            .background(.white)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(L10n.text("分享二维码"))
                        if parts.count > 1 {
                            Stepper(L10n.text("第 {0} / {1} 张", index + 1, parts.count), value: $index, in: 0...parts.count - 1)
                        }
                    }
                }
                Section {
                    Button(copied ? L10n.text("已复制") : L10n.text("复制分享链接")) {
                        BywayPasteboard.copy(item.link)
                        copied = true
                    }
                    ShareLink(item: item.link) { Label(L10n.text("分享链接"), systemImage: "square.and.arrow.up") }
                }
            }
            .navigationTitle(L10n.text("分享"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { dismiss() } } }
        }
    }

    private func qr(_ text: String) -> BywayImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage, let image = context.createCGImage(output, from: output.extent) else { return nil }
        return BywayImage.byway(cgImage: image)
    }
}
