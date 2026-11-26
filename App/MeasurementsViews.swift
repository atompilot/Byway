import SwiftUI

struct TrafficSection: View {
    @ObservedObject var controller: VPNController

    var body: some View {
        Section(L10n.text("流量")) {
            if controller.connected {
                trafficRow(L10n.text("实时速率"), bytes: controller.trafficRates, rate: true)
                trafficRow(L10n.text("本次连接"), bytes: controller.trafficSession)
            }
            trafficRow(L10n.text("累计用量"), bytes: controller.trafficTotal)
            NavigationLink {
                TrafficHistoryView(controller: controller)
            } label: { Label(L10n.text("流量历史"), systemImage: "chart.bar.xaxis") }
            .accessibilityIdentifier("traffic-history")
            NavigationLink {
                ConnectionDiagnosticsView(controller: controller)
            } label: { Label(L10n.text("连接与排障"), systemImage: "network") }
            NavigationLink {
                BandwidthTestView(controller: controller)
            } label: {
                Label(L10n.text("带宽测速"), systemImage: "speedometer")
            }
            .accessibilityIdentifier("bandwidth-test")
        }
    }

    private func trafficRow(_ title: String, bytes: TrafficBytes?, rate: Bool = false) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                Text(L10n.text("上传 {0}", format(bytes?.upload, rate: rate)))
                Text(L10n.text("下载 {0}", format(bytes?.download, rate: rate)))
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if !rate, let bytes {
                    Text(format(bytes.total, rate: false))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func format(_ count: Int64?, rate: Bool) -> String {
        guard let count else { return "—" }
        let amount = count == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: count, countStyle: .decimal)
        return rate ? "\(amount)/s" : amount
    }
}

private struct BandwidthTestView: View {
    @ObservedObject var controller: VPNController

    var body: some View {
        List {
            Section {
                if let node = controller.activeNode {
                    LabeledContent(L10n.text("测试节点"), value: node.name)
                }
                Button {
                    Task { await controller.testBandwidth() }
                } label: {
                    if controller.measuringBandwidth {
                        HStack {
                            ProgressView()
                            Text(L10n.text("正在测速"))
                        }
                    } else {
                        Label(L10n.text("开始测速"), systemImage: "speedometer")
                    }
                }
                .disabled(!controller.canTestBandwidth || controller.activeNode == nil)
                .accessibilityIdentifier("start-bandwidth-test")
            } footer: {
                if !controller.connected {
                    Text(L10n.text("连接 VPN 后可测当前节点的上传和下载速度。"))
                } else {
                    Text(L10n.text("测试会通过当前节点传输约 5 MB 测试数据。"))
                }
            }

            if let measurement = controller.bandwidth {
                Section(L10n.text("测试结果")) {
                    LabeledContent(L10n.text("节点"), value: measurement.nodeName)
                    LabeledContent(L10n.text("下载速度"), value: speed(measurement.result.downloadBitsPerSecond))
                    LabeledContent(L10n.text("上传速度"), value: speed(measurement.result.uploadBitsPerSecond))
                }
                .monospacedDigit()
            }
            if let error = controller.bandwidthError {
                Section {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(L10n.text("带宽测速"))
        .bywayInlineTitle()
    }

    private func speed(_ bitsPerSecond: Int64) -> String {
        let megabits = Double(bitsPerSecond) / 1_000_000
        return "\(megabits.formatted(.number.precision(.fractionLength(0...2)))) Mbps"
    }
}
