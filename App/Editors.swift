import SwiftUI

struct RelayEditor: View {
    let configuration: RelayConfiguration?
    let editable: Bool
    let save: (RelayConfiguration?) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var key: String
    @State private var error: String?

    init(configuration: RelayConfiguration?, editable: Bool, save: @escaping (RelayConfiguration?) throws -> Void) {
        self.configuration = configuration
        self.editable = editable
        self.save = save
        _address = State(initialValue: configuration?.address.absoluteString ?? "")
        _key = State(initialValue: configuration?.deviceKey ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.text("HTTPS 地址"), text: $address)
                        .bywayKeyboardType(.url)
                        .bywayNoAutocapitalization()
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("relay-address")
                    SecureField(L10n.text("设备密钥"), text: $key)
                        .bywayNoAutocapitalization()
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("relay-key")
                } footer: {
                    Text(editable ? L10n.text("隧道连接后，Byway 会连接到你的控制服务。") : L10n.text("断开隧道后可修改控制服务。"))
                }
                .disabled(!editable)
                if configuration != nil && editable {
                    Button(L10n.text("移除控制服务"), role: .destructive) { persist(nil) }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(L10n.text("AI 控制"))
            .bywayInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(editable ? L10n.text("取消") : L10n.text("完成")) { dismiss() }
                }
                if editable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.text("保存")) {
                            do {
                                let configuration = try RelayConfiguration(address: address, deviceKey: key)
                                persist(configuration)
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                        .disabled(address.isEmpty || key.isEmpty)
                    }
                }
            }
        }
    }

    private func persist(_ configuration: RelayConfiguration?) {
        do {
            try save(configuration)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LANControlEditor: View {
    @ObservedObject var control: LANControl
    @ObservedObject var vpn: VPNController
    @Environment(\.openURL) private var openURL
    @State private var copiedWebLink = false
    @State private var copiedIPLink = false
    @State private var showRelay = false
    @State private var copiedAIInstruction = false

    var body: some View {
        Form {
            LocalDeviceSection()
            Section {
                Toggle(L10n.text("允许局域网控制"), isOn: Binding(
                    get: { control.enabled },
                    set: { control.setEnabled($0, vpn: vpn) }
                ))
                .accessibilityIdentifier("lan-control-toggle")
                .disabled(!vpn.ready)
                if control.enabled {
                    LabeledContent(L10n.text("状态"), value: control.state)
                    Toggle(L10n.text("允许局域网发现"), isOn: Binding(
                        get: { control.discoveryEnabled },
                        set: { control.setDiscoveryEnabled($0, vpn: vpn) }
                    ))
                    .accessibilityIdentifier("lan-discovery-toggle")
                    if let address = control.address {
                        Button {
                            BywayPasteboard.copy(aiInstruction(address))
                            copiedAIInstruction = true
                        } label: {
                            Label(copiedAIInstruction ? L10n.text("接入指令已复制") : L10n.text("复制接入指令"), systemImage: "doc.on.doc")
                        }
                        .accessibilityIdentifier("lan-control-copy")
                        LabeledContent(L10n.text("API 地址")) {
                            Text(address).textSelection(.enabled)
                        }
                    }
                }
            } header: {
                Text(L10n.text("把 Byway 接入电脑上的 AI"))
            } footer: {
                if control.enabled {
                    Text(L10n.text("复制后直接粘贴给电脑上的 AI。VPN 连接期间，锁屏也可访问；VPN 断开后，接口只在 Byway 前台开放。"))
                } else {
                    Text(L10n.text("开启后可复制接入指令，交给同一 Wi‑Fi 上的电脑 AI 管理节点和代理设置。请只在信任的 Wi‑Fi 上使用。"))
                }
            }

            Section(L10n.text("出口与连接")) {
                LabeledContent(L10n.text("已选代理节点"), value: vpn.activeNode?.name ?? L10n.text("未选择节点"))
                    .accessibilityIdentifier("ai-selected-exit")
                LabeledContent(L10n.text("VPN 状态"), value: vpn.statusLabel)
                    .accessibilityIdentifier("ai-vpn-status")
            }

            if let address = control.address,
               let webURL = URL(string: control.discovery?.preferredUrl ?? address + "/") {
                Section {
                    LabeledContent(L10n.text("首选地址")) { Text(webURL.absoluteString).textSelection(.enabled) }
                    if control.discoveryEnabled && control.discovery?.mdnsUrl == nil {
                        Text(control.discovery?.status == "unavailable" ? L10n.text("mDNS 不可用，使用 IP 地址。") : L10n.text("正在发布 mDNS 地址。"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button(L10n.text("打开管理网页")) { openURL(webURL) }
                        .disabled(!vpn.connected)
                        .accessibilityIdentifier("open-management-web")
                    Button(copiedWebLink ? L10n.text("网页链接已复制") : L10n.text("复制网页链接")) {
                        BywayPasteboard.copy(url: webURL)
                        copiedWebLink = true
                    }
                    .accessibilityIdentifier("copy-management-link")
                    if control.discovery?.mdnsUrl != nil {
                        Button(copiedIPLink ? L10n.text("IP 链接已复制") : L10n.text("复制 IP 链接")) {
                            BywayPasteboard.copy(url: URL(string: address + "/")!)
                            copiedIPLink = true
                        }
                        .accessibilityIdentifier("copy-management-ip")
                    }
                } header: {
                    Text(L10n.text("管理网页"))
                } footer: {
                    if !vpn.connected {
                        Text(L10n.text("连接 VPN 后可用本机浏览器打开。Byway 保持前台时，其他设备可用链接访问。"))
                    }
                }
            }
            Section {
                NavigationLink(L10n.text("调用日志")) { LANCallLogView(controller: vpn) }
                Button(L10n.text("中继控制设置")) { showRelay = true }
            }
        }
        .bywaySettingsForm()
        .navigationTitle(L10n.text("AI 控制"))
        .bywayInlineTitle()
        .sheet(isPresented: $showRelay) {
            RelayEditor(configuration: vpn.profile.relay, editable: vpn.canEdit, save: vpn.setRelay)
        }
        .onChange(of: control.token) { _, _ in copiedAIInstruction = false }
        .onChange(of: control.address) { _, _ in
            copiedIPLink = false
            copiedWebLink = false
            copiedAIInstruction = false
        }
        .onChange(of: control.discovery?.preferredUrl) { _, _ in copiedWebLink = false }
        .task(id: vpn.connected && control.enabled) {
            guard vpn.connected, control.enabled else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                control.refresh(vpn: vpn)
            }
        }
    }

    private func aiInstruction(_ address: String) -> String {
        L10n.text("请读取 {0}/v1/guide 了解 Byway 的操作接口。\nAuthorization: Bearer {1}", address, control.token)
    }
}

private struct LocalDeviceSection: View {
    @State private var device: DeviceInfo?
    @State private var draft = ""
    @State private var editing = false
    @State private var error: String?

    var body: some View {
        Section(L10n.text("当前设备")) {
            if let device {
                LabeledContent(L10n.text("识别码"), value: device.shortCode)
                    .monospacedDigit()
                    .accessibilityIdentifier("device-short-code")
                if editing {
                    TextField(L10n.text("设备名称"), text: $draft)
                        .accessibilityIdentifier("device-name-input")
                        .onSubmit(save)
                    Button(L10n.text("保存"), action: save)
                    Button(L10n.text("取消"), role: .cancel) {
                        editing = false
                        error = nil
                    }
                } else {
                    LabeledContent(L10n.text("设备名称"), value: device.displayName)
                        .accessibilityIdentifier("device-display-name")
                    Button(L10n.text("修改设备名称")) {
                        draft = device.displayName
                        error = nil
                        editing = true
                    }
                    .accessibilityIdentifier("device-name-edit")
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .task {
            DeviceIdentityStore.observeNameChanges()
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: DeviceIdentityStore.nameDidChange)
            .receive(on: RunLoop.main)) { _ in refresh() }
    }

    private func refresh() {
        do {
            device = try DeviceIdentityStore.local().read()
            if !editing { error = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        do {
            device = try DeviceIdentityStore.local().rename(to: draft)
            editing = false
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
