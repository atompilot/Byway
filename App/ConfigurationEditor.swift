import SwiftUI
import UniformTypeIdentifiers

struct ConfigurationEditor: View {
    @ObservedObject var controller: VPNController
    @State private var error: String?

    var body: some View {
        let library = controller.profile.savedRouting
        List {
            Section(L10n.text("当前配置")) {
                Button {
                    apply("PUT", "/v1/config/routing/active", body: ["useDefault": true])
                } label: {
                    LabeledContent(L10n.text("Byway 默认分流")) {
                        if library.activeID == nil { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                }
                NavigationLink(L10n.text("测试默认分流规则")) {
                    RoutingRuleTestView(controller: controller, configuration: nil)
                }
            }
            Section(L10n.text("已保存的配置")) {
                ForEach(library.configurations) { configuration in
                    NavigationLink {
                        RoutingConfigurationDraft(controller: controller, configuration: configuration)
                    } label: {
                        HStack {
                            Text(configuration.name)
                            Spacer()
                            if configuration.id == library.activeID { Text(L10n.text("当前")).foregroundStyle(.secondary) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .swipeActions(edge: .leading) {
                        Button(L10n.text("启用")) {
                            apply("PUT", "/v1/config/routing/active", body: ["id": configuration.id.uuidString])
                        }
                        .tint(.accentColor)
                    }
                    .swipeActions {
                        Button(L10n.text("删除"), role: .destructive) { apply("DELETE", "/v1/config/routing/" + configuration.id.uuidString) }
                    }
                }
                NavigationLink {
                    RoutingConfigurationDraft(controller: controller, configuration: nil)
                } label: {
                    Label(L10n.text("导入分流配置"), systemImage: "plus")
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .bywaySettingsForm()
        .navigationTitle(L10n.text("分流配置"))
        .bywayInlineTitle()
    }

    private func apply(_ method: String, _ path: String, body: [String: Any]? = nil) {
        Task {
            do {
                try await controller.manage(method, path, body: body)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct RoutingConfigurationDraft: View {
    @ObservedObject var controller: VPNController
    let configuration: SavedRoutingConfiguration?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var text: String
    @State private var preview: ImportedConfigurationReport?
    @State private var error: String?
    @State private var showsFiles = false
    @State private var saving = false
    @FocusState private var editing: Bool

    init(controller: VPNController, configuration: SavedRoutingConfiguration?) {
        self.controller = controller
        self.configuration = configuration
        _name = State(initialValue: configuration?.name ?? "")
        _text = State(initialValue: configuration?.text ?? "")
    }

    var body: some View {
        Form {
            Section(L10n.text("Shadowrocket 或 Clash 配置")) {
                TextField(L10n.text("配置名称"), text: $name)
                Button {
                    showsFiles = true
                } label: { Label(L10n.text("从文件导入"), systemImage: "document") }
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .bywayNoAutocapitalization()
                    .autocorrectionDisabled()
                    .frame(minHeight: 140)
                    .focused($editing)
                    .accessibilityLabel(L10n.text("分流配置文本"))
                    .accessibilityIdentifier("routing-config-text")
                Button(L10n.text("预览分流规则")) { showPreview() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("routing-config-preview")
            }
            if let preview {
                Section(preview.warnings.isEmpty ? L10n.text("预览") : L10n.text("兼容提示")) {
                    LabeledContent(L10n.text("可用规则"), value: L10n.text("{0} 条", preview.ruleCount))
                    ForEach(preview.warnings, id: \.self) { Text($0).foregroundStyle(.secondary) }
                    Button(preview.warnings.isEmpty ? L10n.text("保存配置") : L10n.text("确认兼容提示并保存")) { save() }
                        .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("routing-config-apply")
                }
            }
            if let configuration {
                Section {
                    if controller.profile.savedRouting.activeID != configuration.id {
                        Button(L10n.text("启用这份配置")) { activate(configuration.id) }.disabled(saving)
                    }
                    NavigationLink(L10n.text("测试规则或添加规则")) {
                        RoutingRuleTestView(controller: controller, configuration: configuration.id)
                    }
                }
            }
            if saving { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(configuration == nil ? L10n.text("导入分流配置") : L10n.text("编辑分流配置"))
        .bywayInlineTitle()
        .onChange(of: text) { _, _ in preview = nil }
        .onChange(of: controller.profile.savedRouting.configurations.first { $0.id == configuration?.id }?.text) { old, updated in
            if let old, let updated, text == old { text = updated }
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.plainText, .data]) { result in
            do {
                let url = try result.get()
                text = try readImportFile(url, limit: ShadowrocketConfiguration.maxBytes)
                if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private func showPreview() {
        editing = false
        do {
            preview = try ImportedConfiguration(text: text, enabled: false).report()
            error = nil
        } catch {
            preview = nil
            self.error = error.localizedDescription
        }
    }

    private func save() {
        let id = configuration?.id
        let path = "/v1/config/routing" + (id.map { "/" + $0.uuidString } ?? "")
        let payload: [String: Any] = ["name": name, "text": text, "acceptWarnings": true]
        perform { try await controller.manage(id == nil ? "POST" : "PATCH", path, body: payload) }
    }

    private func activate(_ id: UUID) {
        perform { try await controller.manage("PUT", "/v1/config/routing/active", body: ["id": id.uuidString]) }
    }

    private func perform(_ action: @escaping () async throws -> Data) {
        saving = true
        Task {
            defer { saving = false }
            do {
                _ = try await action()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct RoutingRuleTestView: View {
    @ObservedObject var controller: VPNController
    let configuration: UUID?
    @State private var host = ""
    @State private var match: RoutingRuleMatch?
    @State private var error: String?
    @State private var running = false
    @State private var adding = false
    @State private var kind = "DOMAIN"
    @State private var value = ""
    @State private var policy = "DIRECT"
    @State private var noResolve = false

    var body: some View {
        Form {
            Section(L10n.text("测试目标")) {
                TextField(L10n.text("域名或 IP 地址"), text: $host)
                    .bywayNoAutocapitalization()
                    .autocorrectionDisabled()
                    .bywayKeyboardType(.url)
                    .onSubmit(test)
                Button(L10n.text("测试规则"), action: test).disabled(host.isEmpty || running)
            }
            if let match {
                Section(L10n.text("命中结果")) {
                    LabeledContent(L10n.text("策略"), value: match.policy)
                    LabeledContent(L10n.text("规则"), value: match.rule)
                    if let line = match.lineNumber { LabeledContent(L10n.text("行号"), value: "\(line)") }
                    if let node = match.nodeName { LabeledContent(L10n.text("代理节点"), value: node) }
                    if !match.resolvedAddresses.isEmpty {
                        LabeledContent(L10n.text("解析地址"), value: match.resolvedAddresses.joined(separator: ", "))
                    }
                }
            }
            if let configuration, controller.profile.savedRouting.configurations.contains(where: {
                $0.id == configuration && !RoutingImportDocument.isClash($0.text)
            }) {
                Section {
                    if adding {
                        Picker(L10n.text("匹配方式"), selection: $kind) {
                            ForEach(["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6", "GEOIP"], id: \.self) { Text($0) }
                        }
                        if kind != "GEOIP" { TextField(L10n.text("匹配值"), text: $value).bywayNoAutocapitalization() }
                        if kind.hasPrefix("IP-CIDR") { Toggle("no-resolve", isOn: $noResolve) }
                        Picker(L10n.text("策略"), selection: $policy) {
                            ForEach(["DIRECT", "PROXY", "REJECT"], id: \.self) { Text($0) }
                        }
                        Button(L10n.text("保存并复测"), action: addRule).disabled(running || (kind != "GEOIP" && value.isEmpty))
                    } else {
                        Button(L10n.text("添加规则")) {
                            value = host
                            adding = true
                        }
                    }
                }
            }
            if running { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(L10n.text("测试规则"))
        .bywayInlineTitle()
        .onChange(of: host) { _, _ in match = nil }
    }

    private func test() {
        guard !host.isEmpty, !running else { return }
        run { try await readMatch() }
    }

    private func readMatch() async throws {
        var payload: [String: Any] = ["host": host]
        if let configuration { payload["id"] = configuration.uuidString }
        let data = try await controller.manage("POST", "/v1/config/routing/test-rule", body: payload)
        match = try JSONDecoder().decode(RoutingRuleMatch.self, from: data)
    }

    private func addRule() {
        guard let configuration else { return }
        let payload: [String: Any] = ["type": kind, "value": kind == "GEOIP" ? "CN" : value,
                                      "policy": policy, "noResolve": kind.hasPrefix("IP-CIDR") && noResolve]
        run {
            try await controller.manage("POST", "/v1/config/routing/" + configuration.uuidString + "/rules", body: payload)
            adding = false
            if !host.isEmpty { try await readMatch() }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        running = true
        Task {
            defer { running = false }
            do {
                try await action()
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

func readImportFile(_ url: URL, limit: Int) throws -> String {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit, let text = String(data: data, encoding: .utf8) else {
        throw BywayError.message(L10n.text("请选择受支持大小的 UTF-8 文本文件"))
    }
    return text
}
