import Foundation

enum TrafficRange: String, CaseIterable, Codable, Sendable, Identifiable {
    case today, yesterday, last7days, last30days, all
    var id: Self { self }
    var title: String {
        switch self {
        case .today: "今天"
        case .yesterday: "昨天"
        case .last7days: "近 7 天"
        case .last30days: "近 30 天"
        case .all: "全部"
        }
    }

    func report(_ history: TrafficHistory, now: Date = Date(), calendar: Calendar = .current) -> TrafficReport {
        let today = calendar.startOfDay(for: now)
        let start: Date
        let end: Date
        let unit: Calendar.Component
        switch self {
        case .today:
            (start, end, unit) = (today, calendar.date(byAdding: .day, value: 1, to: today) ?? now, .hour)
        case .yesterday:
            (start, end, unit) = (calendar.date(byAdding: .day, value: -1, to: today) ?? today, today, .hour)
        case .last7days, .last30days:
            (start, end, unit) = (calendar.date(byAdding: .day, value: self == .last7days ? -6 : -29, to: today) ?? today,
                                  calendar.date(byAdding: .day, value: 1, to: today) ?? now, .day)
        case .all:
            let first = min(now, history.recordedSince ?? now)
            (start, end, unit) = (calendar.dateInterval(of: .month, for: first)?.start ?? first,
                                  calendar.dateInterval(of: .month, for: now)?.end ?? now, .month)
        }
        var totals: [Date: TrafficBytes] = [:]
        for (key, sample) in history.samples {
            let instant = Date(timeIntervalSince1970: Double(key))
            guard instant >= start, instant < end, let interval = calendar.dateInterval(of: unit, for: instant) else { continue }
            totals[interval.start, default: TrafficBytes()] = totals[interval.start, default: TrafficBytes()] + sample
        }
        var cursor = start
        var bins: [TrafficBin] = []
        while cursor < end, let next = calendar.date(byAdding: unit, value: 1, to: cursor), next > cursor {
            let usage = totals[cursor]
            bins.append(.init(start: cursor, end: next, usage: usage,
                              state: usage != nil ? .recorded : cursor > now ? .future : .missing))
            cursor = next
        }
        return TrafficReport(range: self, timeZone: calendar.timeZone.identifier, recordedSince: history.recordedSince,
                             lifetime: history.lifetime, total: bins.compactMap(\.usage).reduce(TrafficBytes(), +), bins: bins)
    }
}

struct TrafficHistory: Codable, Sendable {
    var lifetime = TrafficBytes()
    var recordedSince: Date?
    var samples: [Int64: TrafficBytes] = [:]

    mutating func observe(lifetime: TrafficBytes, at time: Date) {
        let amount = lifetime.increase(since: self.lifetime)
        self.lifetime = lifetime
        if recordedSince == nil { recordedSince = time }
        let bucket = Int64(floor(time.timeIntervalSince1970 / 900) * 900)
        samples[bucket, default: TrafficBytes()] = samples[bucket, default: TrafficBytes()] + amount
    }
}

struct TrafficReport: Codable, Sendable {
    let range: TrafficRange
    let timeZone: String
    let recordedSince: Date?
    let lifetime: TrafficBytes
    let total: TrafficBytes
    let bins: [TrafficBin]
}

struct TrafficBin: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case recorded, missing, future }
    let start: Date
    let end: Date
    let usage: TrafficBytes?
    let state: State
    var id: Date { start }
}

struct MobileConnection: Codable, Identifiable, Sendable {
    let id: String
    let source: String
    let destination: String
    let network: String
    let rule: String
    let outbound: String
    let traffic: TrafficBytes
}

struct MobileGatewayDiagnostics: Codable, Sendable {
    var available = false
    var connections: [MobileConnection] = []
    var logs: [String] = []
    var traffic: TrafficSnapshot?
}

struct MobileManagementRequest: Codable, Sendable {
    let management: LANRequest
}

struct MobileManagementReply: Codable, Sendable {
    let status: Int
    let payload: Data
}

struct LANCall: Codable, Identifiable, Sendable {
    var id = UUID()
    let time: Date
    let method: String
    let path: String
    let status: Int
    let durationMilliseconds: Int
}
