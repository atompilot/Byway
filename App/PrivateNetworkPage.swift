import SwiftUI
import UIKit

struct PrivateNetworkPage: View {
    @ObservedObject var controller: VPNController
    var wide = false
    @Environment(\.openURL) private var openURL
    @State private var snapshot: PrivateNetworkSettingsView?
    @State private var selectedID: String?
    @State private var showSettings = false
    @State private var showKey = false
    @State private var confirmLeave = false
    @State private var key = ""
    @State private var busy = false
    @State private var errorText: String?

    private static let endpoint = "/v1/private-network"
    private var state: PrivateNetworkSettingsView {
        snapshot ?? PrivateNetworkSettingsView(controller.profile.privateNetwork)
    }

    var body: some View {
        Group {
            if wide, state.configuration != nil {
                HStack(spacing: 0) {
                    overview.frame(minWidth: 300, idealWidth: 340, maxWidth: 370)
                    Divider()
                    if let peer = state.runtime?.peers.first(where: { $0.id == selectedID }) {
                        PrivatePeerPage(controller: controller, peer: peer)
                            .id(peer.id)
                    } else {
                        ContentUnavailableView("选择设备", systemImage: "point.3.connected.trianglepath.dotted")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                overview
            }
        }
        .navigationTitle("私网")
        .navigationDestination(for: PrivateNetworkPeer.self) { peer in
            PrivatePeerPage(controller: controller, peer: peer).navigationTitle(peer.name)
        }
        .toolbar {
            if state.configuration != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("更多", systemImage: "ellipsis.circle") {
                        Button("退出私网", role: .destructive) { confirmLeave = true }
                    }
                }
            }
        }
        .confirmationDialog("退出这台设备的私网？", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("退出私网", role: .destructive) { change("DELETE", "/membership") }
        } message: {
            Text("再次加入时需要重新授权。")
        }
        .sheet(isPresented: $showSettings) {
            PrivateNetworkForm(settings: state.configuration, actual: state.runtime?.relays) { input in
                let initial = state.configuration == nil
                _ = try await controller.manage("PUT", Self.endpoint + "/config", body: [
                    "provider": input.provider.rawValue, "controlURL": input.controlURL,
                    "relayHosts": input.relayHosts, "deviceName": input.deviceName,
                    "relayMode": input.relayMode.rawValue
                ])
                if initial { _ = try await controller.manage("POST", Self.endpoint + "/join") }
                await refresh()
            }
        }
        .alert("使用入网密钥", isPresented: $showKey) {
            SecureField("一次性入网密钥", text: $key)
            Button("加入") {
                let submitted = key.trimmingCharacters(in: .whitespacesAndNewlines)
                key = ""
                run { snapshot = try await controller.privateNetworkLocalStatus(key: submitted) }
            }
            Button("取消", role: .cancel) { key = "" }
        }
        .task {
            while !Task.isCancelled {
                if !busy { await refresh() }
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    private var overview: some View {
        List {
            if let configuration = state.configuration {
                Section {
                    LabeledContent("私网连接", value: state.state)
                    LabeledContent("当前私网", value: state.runtime?.network ?? configuration.provider.title)
                    if let address = state.runtime?.addresses.first {
                        LabeledContent("本机地址", value: address).textSelection(.enabled)
                    }
                    Button {
                        showSettings = true
                    } label: {
                        LabeledContent("中继设置", value: configuration.relayMode.title)
                    }
                    if state.enabled {
                        Button("暂停私网") { change("PUT", "/state", enabled: false) }
                    } else {
                        Button("恢复私网") { change("PUT", "/state", enabled: true) }
                    }
                }
                if state.enabled, let urlText = state.runtime?.authURL, let url = URL(string: urlText), url.scheme == "https" {
                    Section {
                        Button("在浏览器授权") { openURL(url) }
                        Button("使用入网密钥") { showKey = true }
                    }
                } else if state.runtime?.state == "NeedsLogin" {
                    Section {
                        Button("使用入网密钥") { showKey = true }
                    }
                }
                if state.runtime?.state == "RelayMismatch" {
                    Section {
                        Label("在协调服务更新中继清单。普通代理仍可使用。", systemImage: "exclamationmark.triangle")
                    }
                }
                if let peers = state.runtime?.peers, !peers.isEmpty {
                    Section("其他设备") {
                        ForEach(peers) { peer in
                            if wide {
                                Button { selectedID = peer.id } label: { peerRow(peer) }
                                    .listRowBackground(selectedID == peer.id ? Color.accentColor.opacity(0.12) : Color.clear)
                            } else {
                                NavigationLink(value: peer) { peerRow(peer) }
                            }
                        }
                    }
                }
            } else {
                Section {
                    Text("加入同一个私网后，可以用私网地址访问其他设备。")
                        .foregroundStyle(.secondary)
                    Button("加入私网") { showSettings = true }
                        .accessibilityIdentifier("private-network-join")
                }
            }
            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
        }
        .listStyle(.insetGrouped)
        .disabled(busy)
        .refreshable { await refresh() }
    }

    private func peerRow(_ peer: PrivateNetworkPeer) -> some View {
        LabeledContent(peer.name, value: peer.online ? "在线" : "离线")
    }

    private func refresh() async {
        if let value = try? await controller.privateNetworkLocalStatus() { snapshot = value }
    }

    private func change(_ method: String, _ path: String, enabled: Bool? = nil) {
        run {
            _ = try await controller.manage(method, Self.endpoint + path, body: enabled.map { ["enabled": $0] })
            await refresh()
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        errorText = nil
        Task {
            defer { busy = false }
            do { try await action() }
            catch { errorText = error.localizedDescription }
        }
    }
}

private struct PrivateNetworkForm: View {
    private let settings: PrivateNetworkInput?
    private let actual: PrivateNetworkRuntime.RelayAudit?
    private let save: (PrivateNetworkInput) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var provider: PrivateNetworkInput.Provider
    @State private var controlURL: String
    @State private var tailscaleRelayMode: PrivateNetworkInput.RelayMode
    @State private var relayHosts: String
    @State private var deviceName: String
    @State private var errorText: String?
    @State private var saving = false

    init(settings: PrivateNetworkInput?, actual: PrivateNetworkRuntime.RelayAudit?,
         save: @escaping (PrivateNetworkInput) async throws -> Void) {
        self.settings = settings
        self.actual = actual
        self.save = save
        _provider = State(initialValue: settings?.provider ?? .headscale)
        _controlURL = State(initialValue: settings?.controlURL ?? "")
        _tailscaleRelayMode = State(initialValue: settings?.relayMode ?? .tailscaleDefault)
        _relayHosts = State(initialValue: settings?.relayHosts.joined(separator: ", ") ?? "")
        _deviceName = State(initialValue: settings?.deviceName ?? "")
    }

    private var relayMode: PrivateNetworkInput.RelayMode {
        provider == .tailscale ? tailscaleRelayMode : .strict
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("协调服务") {
                    Picker("加入方式", selection: $provider) {
                        ForEach(PrivateNetworkInput.Provider.allCases, id: \.self) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .disabled(settings != nil)
                    if provider == .headscale {
                        TextField("https://head.example.net", text: $controlURL)
                            .accessibilityLabel("协调服务器")
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(settings != nil)
                    }
                    TextField("设备名（可选）", text: $deviceName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    if provider == .tailscale {
                        Picker("中继模式", selection: $tailscaleRelayMode) {
                            ForEach(PrivateNetworkInput.RelayMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }
                    if relayMode == .strict {
                        TextField("derp.example.net", text: $relayHosts, axis: .vertical)
                            .accessibilityLabel("预期中继域名")
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: {
                    Text("中继")
                } footer: {
                    Text(relayMode == .strict
                         ? "填写协调服务应下发的中继域名，多个域名用逗号或换行分隔。"
                         : "授权后使用 Tailscale 下发的中继。")
                }
                if let actual {
                    Section("实际下发的中继") {
                        let hosts = actual.hosts.isEmpty ? "无" : actual.hosts.joined(separator: ", ")
                        if actual.verified && !actual.hosts.isEmpty {
                            DisclosureGroup("\(actual.hosts.count) 个域名") {
                                Text(hosts).textSelection(.enabled)
                            }
                        } else {
                            Text(hosts).textSelection(.enabled)
                        }
                    }
                }
                if let errorText { Section { Text(errorText).foregroundStyle(.red) } }
            }
            .disabled(saving)
            .navigationTitle(settings == nil ? "加入私网" : "中继设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(settings == nil ? "继续" : "保存") { submit() }.disabled(saving)
                }
            }
        }
    }

    private func submit() {
        let hosts = relayMode == .strict
            ? relayHosts.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isNewline }).map(String.init)
            : []
        let input = PrivateNetworkInput(provider: provider, controlURL: controlURL, relayHosts: hosts,
                                        deviceName: deviceName, relayMode: relayMode)
        saving = true
        errorText = nil
        Task {
            defer { saving = false }
            do { try await save(input.validated()); dismiss() }
            catch { errorText = error.localizedDescription }
        }
    }
}

private struct PrivatePeerPage: View {
    @ObservedObject var controller: VPNController
    let peer: PrivateNetworkPeer
    @State private var result: PrivateNetworkProbe?
    @State private var errorText: String?
    @State private var testing = false

    var body: some View {
        List {
            Section(peer.name) {
                LabeledContent("状态", value: peer.online ? "在线" : "离线")
                ForEach(peer.addresses, id: \.self) { address in
                    LabeledContent("地址", value: address).textSelection(.enabled)
                }
                if !peer.dnsName.isEmpty { LabeledContent("私网域名", value: peer.dnsName).textSelection(.enabled) }
            }
            Section("连接测试") {
                if let result { LabeledContent("最近测试", value: result.summary) }
                if let errorText { Text(errorText).foregroundStyle(.red) }
                Button(testing ? "正在测试…" : "测试连接") { probe() }.disabled(testing || peer.addresses.isEmpty)
                if let address = peer.addresses.first {
                    Button("复制地址") { UIPasteboard.general.string = address }
                }
            }
        }
    }

    private func probe() {
        guard let address = peer.addresses.first else { return }
        testing = true
        errorText = nil
        Task {
            defer { testing = false }
            do {
                let data = try await controller.manage("POST", "/v1/private-network/probe", body: ["address": address])
                result = try JSONDecoder().decode(PrivateNetworkProbe.self, from: data)
            } catch {
                result = nil
                errorText = error.localizedDescription
            }
        }
    }
}
