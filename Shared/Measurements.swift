import Foundation

struct TrafficBytes: Codable, Equatable, Sendable {
    var upload: Int64 = 0
    var download: Int64 = 0

    var total: Int64 { upload + download }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(upload: lhs.upload + rhs.upload, download: lhs.download + rhs.download)
    }

    func increase(since earlier: Self) -> Self {
        Self(upload: max(0, upload - earlier.upload), download: max(0, download - earlier.download))
    }

    func perSecond(over interval: TimeInterval) -> Self {
        Self(upload: Int64(Double(upload) / interval), download: Int64(Double(download) / interval))
    }
}

enum TrafficRequest: String, Codable, Sendable { case traffic }

struct TrafficSnapshot: Codable, Equatable, Sendable {
    let connectionID: UUID
    let session: TrafficBytes
    let lifetime: TrafficBytes?
}

struct TrafficAccumulator {
    private let connectionID = UUID()
    private let previousLifetime: TrafficBytes?
    private var closedInstances = TrafficBytes()
    private var currentInstance = TrafficBytes()

    init(previousLifetime: TrafficBytes?) {
        self.previousLifetime = previousLifetime
    }

    var snapshot: TrafficSnapshot {
        let session = closedInstances + currentInstance
        return TrafficSnapshot(connectionID: connectionID, session: session,
                               lifetime: previousLifetime.map { $0 + session })
    }

    mutating func observe(_ raw: TrafficBytes) {
        currentInstance = TrafficBytes(upload: max(currentInstance.upload, raw.upload),
                                       download: max(currentInstance.download, raw.download))
    }

    mutating func resetEngineCounters() {
        closedInstances = closedInstances + currentInstance
        currentInstance = TrafficBytes()
    }
}

struct BandwidthRequest: Codable, Sendable {
    let bandwidthNodeID: UUID
}

struct BandwidthResult: Codable, Equatable, Sendable {
    let downloadBitsPerSecond: Int64
    let uploadBitsPerSecond: Int64
}

struct BandwidthReply: Codable, Sendable {
    var result: BandwidthResult?
    var error: String?
}
