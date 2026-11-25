import Foundation
import Libbox
import Network
import NetworkExtension

final class TunnelPlatform: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private weak var provider: NEPacketTunnelProvider?
    private var monitor: NWPathMonitor?

    init(provider: NEPacketTunnelProvider) {
        self.provider = provider
    }

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options, let ret0_, let provider else {
            throw BywayError.message("缺少隧道设置")
        }
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        if let prefixes = options.getInet4Address() {
            var addresses: [String] = []
            var masks: [String] = []
            while prefixes.hasNext(), let prefix = prefixes.next() {
                addresses.append(prefix.address())
                masks.append(prefix.mask())
            }
            if !addresses.isEmpty {
                let ipv4 = NEIPv4Settings(addresses: addresses, subnetMasks: masks)
                var included: [NEIPv4Route] = [.default()]
                if let routes = options.getInet4RouteAddress() {
                    while routes.hasNext(), let prefix = routes.next() {
                        included.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
                    }
                }
                ipv4.includedRoutes = included
                if let excluded = options.getInet4RouteExcludeAddress() {
                    var routes: [NEIPv4Route] = []
                    while excluded.hasNext(), let prefix = excluded.next() {
                        routes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
                    }
                    ipv4.excludedRoutes = routes
                }
                settings.ipv4Settings = ipv4
            }
        }
        if let prefixes = options.getInet6Address() {
            var addresses: [String] = []
            var lengths: [NSNumber] = []
            while prefixes.hasNext(), let prefix = prefixes.next() {
                addresses.append(prefix.address())
                lengths.append(NSNumber(value: prefix.prefix()))
            }
            if !addresses.isEmpty {
                let ipv6 = NEIPv6Settings(addresses: addresses, networkPrefixLengths: lengths)
                var included: [NEIPv6Route] = [.default()]
                if let routes = options.getInet6RouteAddress() {
                    while routes.hasNext(), let prefix = routes.next() {
                        included.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
                    }
                }
                ipv6.includedRoutes = included
                if let excluded = options.getInet6RouteExcludeAddress() {
                    var routes: [NEIPv6Route] = []
                    while excluded.hasNext(), let prefix = excluded.next() {
                        routes.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
                    }
                    ipv6.excludedRoutes = routes
                }
                settings.ipv6Settings = ipv6
            }
        }
        let servers = try options.getDNSServerAddress()
        var nameservers: [String] = []
        while servers.hasNext() { nameservers.append(servers.next()) }
        if !nameservers.isEmpty {
            let dns = NEDNSSettings(servers: nameservers)
            dns.matchDomains = [""]
            settings.dnsSettings = dns
        }

        let configuration = DispatchSemaphore(value: 0)
        var configurationError: Error?
        provider.setTunnelNetworkSettings(settings) { error in
            configurationError = error
            configuration.signal()
        }
        guard configuration.wait(timeout: .now() + 20) == .success else {
            throw BywayError.message("等待 iOS 应用隧道设置超时")
        }
        if let configurationError { throw configurationError }

        let fd = LibboxGetTunnelFileDescriptor()
        guard fd >= 0 else { throw BywayError.message("无法取得 iOS 隧道接口") }
        ret0_.pointee = fd
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { throw BywayError.message("缺少网络监听器") }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        let firstUpdate = DispatchSemaphore(value: 0)
        var initial = true
        monitor.pathUpdateHandler = { path in
            let active = path.status == .satisfied ? path.availableInterfaces.first {
                !$0.name.hasPrefix("utun")
            } : nil
            listener.updateDefaultInterface(active?.name ?? "", interfaceIndex: Int32(active?.index ?? -1),
                                            isExpensive: path.isExpensive, isConstrained: path.isConstrained)
            if initial {
                initial = false
                firstUpdate.signal()
            }
        }
        monitor.start(queue: DispatchQueue(label: "cn.splaz.byway.network"))
        if firstUpdate.wait(timeout: .now() + 5) == .timedOut {
            monitor.cancel()
            self.monitor = nil
            throw BywayError.message("等待网络接口超时")
        }
    }

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        monitor?.cancel()
        monitor = nil
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        let interfaces = monitor?.currentPath.availableInterfaces ?? []
        return InterfaceIterator(interfaces.map { item in
            let interface = LibboxNetworkInterface()
            interface.name = item.name
            interface.index = Int32(item.index)
            switch item.type {
            case .wifi: interface.type = LibboxInterfaceTypeWIFI
            case .cellular: interface.type = LibboxInterfaceTypeCellular
            case .wiredEthernet: interface.type = LibboxInterfaceTypeEthernet
            default: interface.type = LibboxInterfaceTypeOther
            }
            return interface
        })
    }

    func registerMyInterface(_ name: String?) {}
    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_ fd: Int32) throws {}
    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }
    func readWIFIState() -> LibboxWIFIState? { nil }
    func localDNSTransport() -> LibboxLocalDNSTransportProtocol? { nil }
    func clearDNSCache() {}
    func writeDebugMessage(_ message: String?) {}
    func send(_ notification: LibboxNotification?) throws {}
    func cancelNotification(_ identifier: String?, typeID: Int32) throws {}
    func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws { throw unavailable }
    func closeNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}
    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32,
                             destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        throw unavailable
    }

    func serviceStop() throws { throw unavailable }
    func serviceReload() throws { throw unavailable }
    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus { LibboxSystemProxyStatus() }
    func setSystemProxyEnabled(_ enabled: Bool) throws { throw unavailable }
    func triggerNativeCrash() throws { throw unavailable }
    func connectSSHAgent(_ ret0_: UnsafeMutablePointer<Int32>?) throws { throw unavailable }
    func usePlatformShell() -> Bool { false }
    func checkPlatformShell() throws { throw unavailable }
    func openShellSession(_ user: LibboxPlatformUser?, command: String?, environ: LibboxStringIteratorProtocol?,
                          term: String?, rows: Int32, cols: Int32) throws -> LibboxShellSessionProtocol {
        throw unavailable
    }
    func lookupUser(_ username: String?) throws -> LibboxPlatformUser { throw unavailable }
    func lookupSFTPServer(_ error: NSErrorPointer) -> String { reportUnavailable(error) }
    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String { reportUnavailable(error) }
    func tailscaleHostname() -> String { "" }
    func usePlatformBridge() -> Bool { false }
    func createBridge(_ options: LibboxBridgeOptions?) throws -> LibboxBridgeSessionProtocol { throw unavailable }

    private var unavailable: BywayError { .message("此隧道未启用该能力") }

    private func reportUnavailable(_ error: NSErrorPointer) -> String {
        error?.pointee = unavailable as NSError
        return ""
    }
}

private final class InterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private let values: [LibboxNetworkInterface]
    private var index = 0

    init(_ values: [LibboxNetworkInterface]) { self.values = values }
    func hasNext() -> Bool { index < values.count }
    func next() -> LibboxNetworkInterface? {
        guard hasNext() else { return nil }
        defer { index += 1 }
        return values[index]
    }
}
