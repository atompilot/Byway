import Charts
import SwiftUI

struct TrafficHistoryView: View {
    @ObservedObject var controller: VPNController
    @State private var range = TrafficRange.today
    @State private var report: TrafficReport?
    @State private var selected: TrafficBin?
    @State private var error: String?

    var body: some View {
        List {
            Picker(L10n.text("时段"), selection: $range) {
                ForEach(TrafficRange.allCases) { Text($0.title).tag($0) }
            }
            if let report {
                Section(L10n.text("流量")) {
                    if range == .all { LabeledContent(L10n.text("累计用量"), value: format(report.lifetime.total)) }
                    LabeledContent(L10n.text("下载"), value: format(report.total.download))
                    LabeledContent(L10n.text("上传"), value: format(report.total.upload))
                }
                if report.recordedSince != nil {
                    Section(L10n.text("流量走势")) {
                        Chart(report.bins) { bin in
                            if let usage = bin.usage {
                                BarMark(x: .value(L10n.text("时段"), bin.start), y: .value(L10n.text("用量"), usage.download))
                                    .foregroundStyle(by: .value(L10n.text("方向"), L10n.text("下载")))
                                BarMark(x: .value(L10n.text("时段"), bin.start), y: .value(L10n.text("用量"), usage.upload))
                                    .foregroundStyle(by: .value(L10n.text("方向"), L10n.text("上传")))
                            }
                        }
                        .chartXScale(domain: chartRange(report))
                        .chartYAxis {
                            AxisMarks { mark in
                                AxisGridLine()
                                AxisValueLabel { if let bytes = mark.as(Int64.self) { Text(format(bytes)) } }
                            }
                        }
                        .frame(minHeight: 150)
                        .accessibilityLabel(L10n.text("上传与下载流量柱形图"))
                    }
                    Section(L10n.text("时段明细")) {
                        ForEach(report.bins.reversed()) { bin in
                            Button { selected = bin } label: {
                                LabeledContent(label(bin.start), value: bin.usage.map { format($0.total) }
                                                ?? (bin.state == .future ? L10n.text("尚未到达") : L10n.text("无采样")))
                            }.buttonStyle(.plain)
                        }
                    }
                } else {
                    Text(L10n.text("连接 VPN 后开始记录分时流量。")).foregroundStyle(.secondary)
                }
            } else if error == nil {
                ProgressView()
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(L10n.text("流量历史"))
        .bywayInlineTitle()
        .task(id: range) { await reload() }
        .refreshable { await reload() }
        .sheet(item: $selected) { bin in
            NavigationStack {
                Form {
                    if let usage = bin.usage {
                        LabeledContent(L10n.text("下载"), value: format(usage.download))
                        LabeledContent(L10n.text("上传"), value: format(usage.upload))
                        LabeledContent(L10n.text("合计"), value: format(usage.total))
                    } else {
                        Text(bin.state == .future ? L10n.text("尚未到达该时段") : L10n.text("该时段没有采样记录"))
                    }
                }
                .navigationTitle(label(bin.start))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { selected = nil } } }
            }
            .bywaySheetDetents()
        }
    }

    private func reload() async {
        do {
            let response = try await controller.manage("GET", "/v1/statistics/history?range=" + range.rawValue)
            guard !Task.isCancelled else { return }
            report = try JSONDecoder().decode(TrafficReport.self, from: response)
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func label(_ date: Date) -> String {
        switch range {
        case .today, .yesterday: date.formatted(date: .omitted, time: .shortened)
        case .last7days, .last30days: date.formatted(.dateTime.month().day())
        case .all: date.formatted(.dateTime.year().month())
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }

    private func chartRange(_ report: TrafficReport) -> ClosedRange<Date> {
        let start = report.bins.first?.start ?? .now
        return start...(report.bins.last?.end ?? start)
    }
}

struct ConnectionDiagnosticsView: View {
    @ObservedObject var controller: VPNController
    @State private var connections: [MobileConnection] = []
    @State private var available = false
    @State private var loading = false
    @State private var error: String?
    @State private var confirmCloseAll = false

    var body: some View {
        List {
            Section {
                NavigationLink(L10n.text("内核日志")) { EngineLogView(controller: controller) }
                if !connections.isEmpty {
                    Button(L10n.text("断开全部连接"), role: .destructive) { confirmCloseAll = true }
                }
            }
            Section(L10n.text("活跃连接")) {
                if loading && connections.isEmpty { ProgressView() }
                if !available && !loading {
                    Text(controller.connected ? L10n.text("当前无法读取连接") : L10n.text("连接 VPN 后可查看活跃连接"))
                        .foregroundStyle(.secondary)
                }
                if available && connections.isEmpty && !loading {
                    Text(L10n.text("当前没有活跃连接")).foregroundStyle(.secondary)
                }
                ForEach(connections) { connection in
                    NavigationLink {
                        connectionDetails(connection)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.destination)
                            Text("\(connection.network.uppercased()) · \(connection.outbound)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(L10n.text("断开"), role: .destructive) { close(connection.id) }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(L10n.text("连接与排障"))
        .bywayInlineTitle()
        .task { await reload() }
        .refreshable { await reload() }
        .toolbar { ToolbarItem(placement: .primaryAction) {
            Button(L10n.text("刷新"), systemImage: "arrow.clockwise") { Task { await reload() } }.disabled(loading)
        } }
        .confirmationDialog(L10n.text("断开全部活跃连接？"), isPresented: $confirmCloseAll) {
            Button(L10n.text("断开全部连接"), role: .destructive) { close(nil) }
        }
    }

    private func connectionDetails(_ connection: MobileConnection) -> some View {
        Form {
            LabeledContent(L10n.text("来源"), value: connection.source)
            LabeledContent(L10n.text("目标"), value: connection.destination)
            LabeledContent(L10n.text("协议"), value: connection.network.uppercased())
            LabeledContent(L10n.text("命中规则"), value: connection.rule)
            LabeledContent(L10n.text("出口"), value: connection.outbound)
            LabeledContent(L10n.text("下载"), value: ByteCountFormatter.string(fromByteCount: connection.traffic.download, countStyle: .decimal))
            LabeledContent(L10n.text("上传"), value: ByteCountFormatter.string(fromByteCount: connection.traffic.upload, countStyle: .decimal))
        }.navigationTitle(L10n.text("连接详情"))
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let data = try await controller.manage("GET", "/v1/connections")
            let result = try JSONDecoder().decode(Report.self, from: data)
            (connections, available) = (result.connections, result.available)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func close(_ id: String?) {
        Task {
            do {
                try await controller.manage("DELETE", "/v1/connections" + (id.map { "/" + $0 } ?? ""))
                await reload()
            } catch { self.error = error.localizedDescription }
        }
    }

    private struct Report: Decodable {
        let available: Bool
        let connections: [MobileConnection]
    }
}

private struct EngineLogView: View {
    @ObservedObject var controller: VPNController
    @State private var logs: [String] = []
    @State private var state = L10n.text("正在读取")

    var body: some View {
        List {
            if logs.isEmpty { Text(state).foregroundStyle(.secondary) }
            ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            }
        }
        .navigationTitle(L10n.text("内核日志"))
        .bywayInlineTitle()
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        do {
            let data = try await controller.manage("GET", "/v1/diagnostics/engine")
            let result = try JSONDecoder().decode(Report.self, from: data)
            logs = result.logs
            state = result.available ? L10n.text("当前没有日志") : L10n.text("当前无法读取内核日志")
        } catch { state = error.localizedDescription }
    }

    private struct Report: Decodable {
        let available: Bool
        let logs: [String]
    }
}

struct LANCallLogView: View {
    @ObservedObject var controller: VPNController
    @State private var calls: [LANCall] = []
    @State private var message = L10n.text("正在读取")

    var body: some View {
        List {
            if calls.isEmpty { Text(message).foregroundStyle(.secondary) }
            ForEach(calls.reversed()) { call in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(call.method) \(call.path)").font(.system(.footnote, design: .monospaced))
                    Text("\(call.time.formatted(date: .omitted, time: .standard)) · \(call.status) · \(call.durationMilliseconds) ms")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(L10n.text("AI 调用日志"))
        .bywayInlineTitle()
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        do {
            let data = try await controller.manage("GET", "/v1/diagnostics/api-calls")
            calls = try JSONDecoder().decode([LANCall].self, from: data)
            message = L10n.text("暂无调用记录")
        } catch { message = error.localizedDescription }
    }
}
