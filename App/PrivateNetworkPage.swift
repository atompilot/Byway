import SwiftUI
#if os(iOS)
import UIKit
#endif

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
                #if os(macOS)
                HStack(spacing: 0) {
                    macOverview
                        .frame(minWidth: 320, idealWidth: 360, maxWidth: 400)
                    Divider()
                    if let peer = state.runtime?.peers.first(where: { $0.id == selectedID }) {
                        PrivatePeerPage(controller: controller, peer: peer).id(peer.id)
                    } else if state.runtime?.peers.isEmpty == true {
                        ContentUnavailableView {
                            Label(L10n.text("暂无其他设备"), systemImage: "point.3.connected.trianglepath.dotted")
                        } description: {
                            Text(L10n.text("同一私网内的 iPhone、iPad、Windows 或 Mac 会出现在这里。"))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView {
                            Label(L10n.text("选择设备"), systemImage: "point.3.connected.trianglepath.dotted")
                        } description: {
                            Text(L10n.text("从左侧查看在线状态、地址和连接测试。"))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                #else
                HStack(spacing: 0) {
                    overview.frame(minWidth: 300, idealWidth: 340, maxWidth: 370)
                    Divider()
                    if let peer = state.runtime?.peers.first(where: { $0.id == selectedID }) {
                        PrivatePeerPage(controller: controller, peer: peer)
                            .id(peer.id)
                    } else {
                        ContentUnavailableView(L10n.text("选择设备"), systemImage: "point.3.connected.trianglepath.dotted")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                #endif
            } else {
                overview
            }
        }
        .navigationTitle(L10n.text("私网"))
        .navigationDestination(for: PrivateNetworkPeer.self) { peer in
            PrivatePeerPage(controller: controller, peer: peer).navigationTitle(peer.name)
        }
        .toolbar {
            if state.configuration != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu(L10n.text("更多"), systemImage: "ellipsis.circle") {
                        Button(L10n.text("退出私网"), role: .destructive) { confirmLeave = true }
                    }
                }
            }
        }
        .confirmationDialog(L10n.text("退出这台设备的私网？"), isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(L10n.text("退出私网"), role: .destructive) { change("DELETE", "/membership") }
        } message: {
            Text(L10n.text("再次加入时需要重新授权。"))
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
        .alert(L10n.text("使用入网密钥"), isPresented: $showKey) {
            SecureField(L10n.text("一次性入网密钥"), text: $key)
            Button(L10n.text("加入")) {
                let submitted = key.trimmingCharacters(in: .whitespacesAndNewlines)
                key = ""
                run { snapshot = try await controller.privateNetworkLocalStatus(key: submitted) }
            }
            Button(L10n.text("取消"), role: .cancel) { key = "" }
        }
        .task {
            while !Task.isCancelled {
                if !busy { await refresh() }
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    #if os(macOS)
    /// Mac 的私网页：左栏用卡片叠状态、操作和设备，右栏展示选中设备的详情。
    private var macOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BywayStyle.Spacing.l) {
                if let configuration = state.configuration {
                    VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
                        BywaySectionHeader(title: L10n.text("私网连接"))
                        BywayCard {
                            VStack(spacing: BywayStyle.Spacing.s) {
                                cardRow(L10n.text("状态"), state.state)
                                Divider()
                                cardRow(L10n.text("当前私网"), state.runtime?.network ?? configuration.provider.title)
                                if let address = state.runtime?.addresses.first {
                                    Divider()
                                    cardRow(L10n.text("本机地址"), address, monospaced: true)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
                        BywaySectionHeader(title: L10n.text("操作"))
                        BywayCard(padding: 0) {
                            VStack(spacing: 0) {
                                cardButton(L10n.text("中继设置"), value: configuration.relayMode.title, symbol: "antenna.radiowaves.left.and.right") {
                                    showSettings = true
                                }
                                Divider().padding(.leading, BywayStyle.Metrics.cardPadding)
                                cardButton(state.enabled ? L10n.text("暂停私网") : L10n.text("恢复私网"),
                                           symbol: state.enabled ? "pause.circle" : "play.circle") {
                                    change("PUT", "/state", enabled: !state.enabled)
                                }
                                if state.enabled, let urlText = state.runtime?.authURL,
                                   let url = URL(string: urlText), url.scheme == "https" {
                                    Divider().padding(.leading, BywayStyle.Metrics.cardPadding)
                                    cardButton(L10n.text("在浏览器授权"), symbol: "safari") { openURL(url) }
                                }
                                if state.runtime?.state == "NeedsLogin" || state.enabled {
                                    Divider().padding(.leading, BywayStyle.Metrics.cardPadding)
                                    cardButton(L10n.text("使用入网密钥"), symbol: "key") { showKey = true }
                                }
                            }
                        }
                    }

                    if state.runtime?.state == "RelayMismatch" {
                        BywayCard {
                            Label(L10n.text("在协调服务更新中继清单。普通代理仍可使用。"), systemImage: "exclamationmark.triangle")
                                .font(BywayStyle.Typography.metadata)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
                        BywaySectionHeader(title: L10n.text("其他设备"))
                        BywayCard(padding: 0) {
                            VStack(spacing: 0) {
                                let peers = state.runtime?.peers ?? []
                                if peers.isEmpty {
                                    Text(L10n.text("暂无其他设备"))
                                        .font(BywayStyle.Typography.metadata)
                                        .foregroundStyle(.secondary)
                                        .padding(BywayStyle.Metrics.cardPadding)
                                }
                                ForEach(Array(peers.enumerated()), id: \.element.id) { index, peer in
                                    peerRowMac(peer)
                                    if index < peers.count - 1 {
                                        Divider().padding(.leading, BywayStyle.Metrics.cardPadding)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
                        BywaySectionHeader(title: L10n.text("私网"))
                        BywayCard {
                            VStack(alignment: .leading, spacing: BywayStyle.Spacing.m) {
                                Text(L10n.text("加入同一个私网后，可以用私网地址访问其他设备。"))
                                    .font(BywayStyle.Typography.rowTitle)
                                    .foregroundStyle(.secondary)
                                Button(L10n.text("加入私网")) { showSettings = true }
                                    .buttonStyle(MacProminentButtonStyle())
                                    .accessibilityIdentifier("private-network-join")
                            }
                        }
                    }
                }
                if let errorText {
                    Text(errorText)
                        .font(BywayStyle.Typography.metadata)
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
            }
            .padding(BywayStyle.Metrics.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func cardRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(BywayStyle.Typography.rowTitle).foregroundStyle(.secondary)
            Spacer(minLength: BywayStyle.Spacing.l)
            Text(value)
                .font(monospaced ? BywayStyle.Typography.monospacedValue : BywayStyle.Typography.rowTitle)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func cardButton(_ title: String, value: String? = nil, symbol: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: BywayStyle.Spacing.s) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bywayBrand)
                    .frame(width: 18)
                Text(title).font(BywayStyle.Typography.rowTitle)
                Spacer(minLength: BywayStyle.Spacing.s)
                if let value {
                    Text(value).font(BywayStyle.Typography.metadata).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, BywayStyle.Metrics.cardPadding)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func peerRowMac(_ peer: PrivateNetworkPeer) -> some View {
        Button { selectedID = peer.id } label: {
            HStack(spacing: BywayStyle.Spacing.s) {
                Circle()
                    .fill(peer.online ? Color.bywayPositive : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
                Text(peer.name).font(BywayStyle.Typography.rowTitle).lineLimit(1)
                Spacer(minLength: BywayStyle.Spacing.s)
                Text(peer.online ? L10n.text("在线") : L10n.text("离线"))
                    .font(BywayStyle.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, BywayStyle.Metrics.cardPadding)
            .frame(minHeight: 32)
            .background(selectedID == peer.id ? Color.bywayBrand.opacity(0.12) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif

    private var overview: some View {
        List {
            if let configuration = state.configuration {
                Section {
                    LabeledContent(L10n.text("私网连接"), value: state.state)
                    LabeledContent(L10n.text("当前私网"), value: state.runtime?.network ?? configuration.provider.title)
                    if let address = state.runtime?.addresses.first {
                        LabeledContent(L10n.text("本机地址"), value: address).textSelection(.enabled)
                    }
                    Button {
                        showSettings = true
                    } label: {
                        LabeledContent(L10n.text("中继设置"), value: configuration.relayMode.title)
                    }
                    if state.enabled {
                        Button(L10n.text("暂停私网")) { change("PUT", "/state", enabled: false) }
                    } else {
                        Button(L10n.text("恢复私网")) { change("PUT", "/state", enabled: true) }
                    }
                }
                if state.enabled, let urlText = state.runtime?.authURL, let url = URL(string: urlText), url.scheme == "https" {
                    Section {
                        Button(L10n.text("在浏览器授权")) { openURL(url) }
                        Button(L10n.text("使用入网密钥")) { showKey = true }
                    }
                } else if state.runtime?.state == "NeedsLogin" {
                    Section {
                        Button(L10n.text("使用入网密钥")) { showKey = true }
                    }
                }
                if state.runtime?.state == "RelayMismatch" {
                    Section {
                        Label(L10n.text("在协调服务更新中继清单。普通代理仍可使用。"), systemImage: "exclamationmark.triangle")
                    }
                }
                if let peers = state.runtime?.peers, !peers.isEmpty {
                    Section(L10n.text("其他设备")) {
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
                    Text(L10n.text("加入同一个私网后，可以用私网地址访问其他设备。"))
                        .foregroundStyle(.secondary)
                    Button(L10n.text("加入私网")) { showSettings = true }
                        .accessibilityIdentifier("private-network-join")
                }
            }
            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
        }
        .bywayInsetGroupedList()
        .disabled(busy)
        .refreshable { await refresh() }
    }

    private func peerRow(_ peer: PrivateNetworkPeer) -> some View {
        LabeledContent(peer.name, value: peer.online ? L10n.text("在线") : L10n.text("离线"))
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
                Section(L10n.text("协调服务")) {
                    Picker(L10n.text("加入方式"), selection: $provider) {
                        ForEach(PrivateNetworkInput.Provider.allCases, id: \.self) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .disabled(settings != nil)
                    if provider == .headscale {
                        TextField("https://head.example.net", text: $controlURL)
                            .accessibilityLabel(L10n.text("协调服务器"))
                            .bywayURLContentType()
                            .bywayKeyboardType(.url)
                            .bywayNoAutocapitalization()
                            .autocorrectionDisabled()
                            .disabled(settings != nil)
                    }
                    TextField(L10n.text("设备名（可选）"), text: $deviceName)
                        .bywayNoAutocapitalization().autocorrectionDisabled()
                }
                Section {
                    if provider == .tailscale {
                        Picker(L10n.text("中继模式"), selection: $tailscaleRelayMode) {
                            ForEach(PrivateNetworkInput.RelayMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }
                    if relayMode == .strict {
                        TextField("derp.example.net", text: $relayHosts, axis: .vertical)
                            .accessibilityLabel(L10n.text("预期中继域名"))
                            .bywayNoAutocapitalization().autocorrectionDisabled()
                    }
                } header: {
                    Text(L10n.text("中继"))
                } footer: {
                    Text(relayMode == .strict
                         ? L10n.text("填写协调服务应下发的中继域名，多个域名用逗号或换行分隔。")
                         : L10n.text("授权后使用 Tailscale 下发的中继。"))
                }
                if let actual {
                    Section(L10n.text("实际下发的中继")) {
                        let hosts = actual.hosts.isEmpty ? L10n.text("无") : actual.hosts.joined(separator: ", ")
                        if actual.verified && !actual.hosts.isEmpty {
                            DisclosureGroup(L10n.text("{0} 个域名", actual.hosts.count)) {
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
            .navigationTitle(settings == nil ? L10n.text("加入私网") : L10n.text("中继设置"))
            .bywayInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(settings == nil ? L10n.text("继续") : L10n.text("保存")) { submit() }.disabled(saving)
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
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: BywayStyle.Spacing.l) {
                HStack(alignment: .firstTextBaseline, spacing: BywayStyle.Spacing.s) {
                    Circle()
                        .fill(peer.online ? Color.bywayPositive : Color.secondary.opacity(0.35))
                        .frame(width: 8, height: 8)
                    Text(peer.name).font(BywayStyle.Typography.pageTitle)
                    Spacer(minLength: 0)
                    Text(peer.online ? L10n.text("在线") : L10n.text("离线"))
                        .font(BywayStyle.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
                BywayCard {
                    VStack(spacing: BywayStyle.Spacing.s) {
                        ForEach(Array(peer.addresses.enumerated()), id: \.offset) { index, address in
                            if index > 0 { Divider() }
                            HStack(alignment: .firstTextBaseline) {
                                Text(L10n.text("地址")).foregroundStyle(.secondary)
                                Spacer(minLength: BywayStyle.Spacing.l)
                                Text(address)
                                    .font(BywayStyle.Typography.monospacedValue)
                                    .textSelection(.enabled)
                            }
                            .font(BywayStyle.Typography.rowTitle)
                        }
                        if !peer.dnsName.isEmpty {
                            Divider()
                            HStack(alignment: .firstTextBaseline) {
                                Text(L10n.text("私网域名")).foregroundStyle(.secondary)
                                Spacer(minLength: BywayStyle.Spacing.l)
                                Text(peer.dnsName)
                                    .font(BywayStyle.Typography.monospacedValue)
                                    .textSelection(.enabled)
                            }
                            .font(BywayStyle.Typography.rowTitle)
                        }
                    }
                }
                BywayCard {
                    VStack(alignment: .leading, spacing: BywayStyle.Spacing.s) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(L10n.text("连接测试")).font(BywayStyle.Typography.metadata.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            if let result {
                                Text(result.summary).font(BywayStyle.Typography.metadata).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: BywayStyle.Spacing.s) {
                            Button(testing ? L10n.text("正在测试…") : L10n.text("测试连接")) { probe() }
                                .buttonStyle(MacProminentButtonStyle())
                                .frame(width: 108)
                                .disabled(testing || peer.addresses.isEmpty)
                            if let address = peer.addresses.first {
                                Button(L10n.text("复制地址")) { BywayPasteboard.copy(address) }
                                    .buttonStyle(.bordered)
                            }
                        }
                        if let errorText {
                            Text(errorText).font(BywayStyle.Typography.metadata).foregroundStyle(.red)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(BywayStyle.Metrics.pagePadding)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        #else
        List {
            Section(peer.name) {
                LabeledContent(L10n.text("状态"), value: peer.online ? L10n.text("在线") : L10n.text("离线"))
                ForEach(peer.addresses, id: \.self) { address in
                    LabeledContent(L10n.text("地址"), value: address).textSelection(.enabled)
                }
                if !peer.dnsName.isEmpty { LabeledContent(L10n.text("私网域名"), value: peer.dnsName).textSelection(.enabled) }
            }
            Section(L10n.text("连接测试")) {
                if let result { LabeledContent(L10n.text("最近测试"), value: result.summary) }
                if let errorText { Text(errorText).foregroundStyle(.red) }
                Button(testing ? L10n.text("正在测试…") : L10n.text("测试连接")) { probe() }.disabled(testing || peer.addresses.isEmpty)
                if let address = peer.addresses.first {
                    Button(L10n.text("复制地址")) { BywayPasteboard.copy(address) }
                }
            }
        }
        #endif
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
