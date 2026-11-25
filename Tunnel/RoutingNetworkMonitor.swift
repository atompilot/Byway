import Dispatch
import Network

final class RoutingNetworkMonitor {
    let updates: AsyncStream<RoutingNetwork?>
    let initial: RoutingNetwork?
    private let monitor = NWPathMonitor()
    private let continuation: AsyncStream<RoutingNetwork?>.Continuation

    init() {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        let firstUpdate = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { [continuation] path in
            continuation.yield(Self.network(for: path))
            firstUpdate.signal()
        }
        monitor.start(queue: DispatchQueue(label: "cn.splaz.byway.routing"))
        _ = firstUpdate.wait(timeout: .now() + 1)
        initial = Self.network(for: monitor.currentPath)
    }

    func stop() {
        monitor.cancel()
        continuation.finish()
    }

    deinit { stop() }

    private static func network(for path: NWPath) -> RoutingNetwork? {
        guard path.status == .satisfied else { return nil }
        let physical: [NWInterface.InterfaceType] = [.wiredEthernet, .wifi, .cellular]
        let type = physical.first { path.usesInterfaceType($0) }
            ?? path.availableInterfaces.first { physical.contains($0.type) }?.type
        switch type {
        case .wiredEthernet: return .wired
        case .wifi: return .wifi
        case .cellular: return .cellular
        default: return .other
        }
    }
}
