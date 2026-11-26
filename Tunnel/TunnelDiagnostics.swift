import Foundation
import Libbox

final class TunnelDiagnostics {
    private let handler = TunnelDiagnosticHandler()
    private let client: LibboxCommandClient

    init?() {
        let options = LibboxCommandClientOptions()
        options.statusInterval = 1_000_000_000
        options.addCommand(LibboxCommandConnections)
        options.addCommand(LibboxCommandLog)
        guard let client = LibboxNewCommandClient(handler, options), (try? client.connect()) != nil else { return nil }
        self.client = client
    }

    func stop() { try? client.disconnect() }

    func snapshot() -> MobileGatewayDiagnostics { handler.snapshot() }

    func close(_ id: String?) throws {
        if let id {
            guard UUID(uuidString: id) != nil else { throw LANFailure(422, "连接 ID 无效") }
            try client.closeConnection(id)
        } else {
            try client.closeConnections()
        }
    }
}

private final class TunnelDiagnosticHandler: NSObject, LibboxCommandClientHandlerProtocol {
    private let lock = NSLock()
    private let connections = LibboxNewConnections()
    private var latest = MobileGatewayDiagnostics()

    func snapshot() -> MobileGatewayDiagnostics { lock.withLock { latest } }
    func connected() { lock.withLock { latest.available = true } }
    func disconnected(_ message: String?) {
        lock.withLock {
            latest.available = false
            latest.connections.removeAll()
        }
    }
    func clearLogs() { lock.withLock { latest.logs.removeAll() } }

    /// Librebox 的迭代器会回到 Go，不能在本机锁内调用；先取出数据再加锁写入。
    func write(_ events: LibboxConnectionEvents?) {
        guard let events else { return }
        connections?.apply(events)
        let active = connections?.iterator()
        var snapshot: [MobileConnection] = []
        while let connection = active?.next(), snapshot.count < 500 {
            guard connection.closedAt == 0 else { continue }
            snapshot.append(MobileConnection(id: connection.id_, source: connection.source,
                destination: connection.displayDestination(), network: connection.network,
                rule: connection.rule, outbound: connection.outbound,
                traffic: TrafficBytes(upload: connection.uplinkTotal, download: connection.downlinkTotal)))
        }
        lock.withLock { latest.connections = snapshot }
    }

    func writeLogs(_ messageList: LibboxLogIteratorProtocol?) {
        guard let messageList else { return }
        var lines: [String] = []
        while let entry = messageList.next() {
            let message = entry.message
                .replacingOccurrences(of: #"(?i)[a-z][a-z0-9+.-]*://[^\s]+"#, with: "[链接已隐藏]", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)(password|uuid|token|authorization)([=: ]+)[^ ,;]+"#,
                                      with: "$1=[已隐藏]", options: .regularExpression)
            lines.append(String(message.prefix(500)))
            if lines.count >= 100 { break }
        }
        guard !lines.isEmpty else { return }
        lock.withLock {
            latest.logs.append(contentsOf: lines)
            if latest.logs.count > 100 { latest.logs.removeFirst(latest.logs.count - 100) }
        }
    }

    func initializeClashMode(_ modeList: LibboxStringIteratorProtocol?, currentMode: String?) {}
    func setDefaultLogLevel(_ level: Int32) {}
    func updateClashMode(_ newMode: String?) {}
    func writeGroups(_ message: LibboxOutboundGroupIteratorProtocol?) {}
    func writeOutbounds(_ message: LibboxOutboundGroupItemIteratorProtocol?) {}
    func writeStatus(_ message: LibboxStatusMessage?) {}
}
