import SwiftUI

struct DNSSettingsView: View {
    @ObservedObject var controller: VPNController
    @State private var addingServer = false
    @State private var error: String?

    private var settings: DNSSettings { controller.profile.dnsSettings }

    var body: some View {
        Form {
            Section {
                Picker("模式", selection: Binding(get: { settings.mode }, set: { mode in
                    update { $0.mode = mode }
                })) {
                    ForEach(DNSSettings.Mode.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("dns-mode")

                if settings.mode == .manual {
                    Picker("当前服务器", selection: Binding(get: { settings.selected?.id ?? "" }, set: { id in
                        update { $0.selectedID = id }
                    })) {
                        ForEach(settings.servers) { Text($0.name).tag($0.id) }
                    }
                    .accessibilityIdentifier("dns-manual-server")
                }
            } footer: {
                Text(modeDescription)
            }

            Section("加密 DNS") {
                ForEach(settings.servers) { server in
                    NavigationLink {
                        DNSServerEditor(controller: controller, draft: server, isNew: false)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(server.name)
                            Text(server.address)
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        }
                    }
                }
                Button {
                    addingServer = true
                } label: {
                    Label("添加 DNS", systemImage: "plus")
                }
                .accessibilityIdentifier("add-dns")
                .disabled(settings.servers.count >= DNSSettings.maxServers)
            }
        }
        .disabled(controller.busy)
        .navigationTitle("DNS")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $addingServer) {
            NavigationStack {
                DNSServerEditor(controller: controller, draft: DNSServer(), isNew: true)
            }
        }
        .dnsError($error)
    }

    private var modeDescription: String {
        switch settings.mode {
        case .configuration: "使用分流配置里的 DNS。配置未指定 DNS 时自动选择。"
        case .automatic: "通过当前出口测试已添加的服务器。主用 DNS 连续失败时自动切换。"
        case .manual: "通过当前出口使用所选服务器。"
        }
    }

    private func update(_ change: (inout DNSSettings) -> Void) {
        var next = settings
        change(&next)
        Task {
            do { try await controller.saveDNS(next) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct DNSServerEditor: View {
    @ObservedObject var controller: VPNController
    @State var draft: DNSServer
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $draft.name)
                    .accessibilityIdentifier("dns-name")
                TextField("HTTPS DNS 地址", text: $draft.address, prompt: Text("https://dns.example.com/dns-query"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("dns-address")
            }
            Section {
                TextField("连接 IP（可选）", text: Binding(get: { draft.connectionIP ?? "" }, set: { draft.connectionIP = $0 }))
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("dns-connection-ip")
            } footer: {
                Text("填写连接 IP 可以直接连接该地址。HTTPS 仍用 DNS 地址中的域名校验证书。")
            }
            if !isNew, controller.profile.dnsSettings.servers.count > 1 {
                Section {
                    Button("删除 DNS", role: .destructive) { save(removing: true) }
                }
            }
        }
        .disabled(controller.busy)
        .navigationTitle(isNew ? "添加 DNS" : "编辑 DNS")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save(removing: false) }
                    .disabled(controller.busy || draft.name.isEmpty || draft.address.isEmpty)
                    .accessibilityIdentifier("save-dns")
            }
        }
        .dnsError($error)
    }

    private func save(removing: Bool) {
        var next = controller.profile.dnsSettings
        if isNew {
            next.servers.append(draft)
        } else if let index = next.servers.firstIndex(where: { $0.id == draft.id }) {
            if removing {
                next.servers.remove(at: index)
                if next.selectedID == draft.id { next.selectedID = next.servers.first?.id }
            } else {
                next.servers[index] = draft
            }
        } else {
            error = "该服务器已删除"
            return
        }
        Task {
            do {
                try await controller.saveDNS(next)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private extension View {
    func dnsError(_ message: Binding<String?>) -> some View {
        alert("无法保存 DNS 设置", isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("好", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
