import Darwin
import Foundation
import Network
import OSLog

@MainActor
final class LANServer {
    private static let logger = Logger(subsystem: "cn.splaz.byway", category: "LANControl")
    private let port: NWEndpoint.Port

    private(set) var endpoint = LANEndpoint.off
    private var settings: LANSettings?
    private var store: ProfileStore?
    private var handle: ((LANRequest) async -> LANResponse)?
    private var didChange: ((LANEndpoint) -> Void)?
    private var monitor: NWPathMonitor?
    private var listener: NWListener?
    private var connections: [UUID: LANConnection] = [:]
    private var network: LANSubnet?
    private var lease: LANLease?
    private var retry: Task<Void, Never>?
    private var ended = false
    private let discovery = LANDiscoveryPublisher()
    private var discoveryChoice: Bool?

    init(port: NWEndpoint.Port = 8766) { self.port = port }

    func start(_ settings: LANSettings, store: ProfileStore, didChange: @escaping (LANEndpoint) -> Void,
               handle: @escaping (LANRequest) async -> LANResponse) {
        guard !ended else { return }
        if self.settings == settings {
            refreshDiscovery()
            return
        }
        stop()
        self.settings = settings
        self.store = store
        self.handle = handle
        self.didChange = didChange
        #if targetEnvironment(simulator) || BYWAY_LOCAL_TEST
        setNetwork(LANSubnet(address: IPv4Address.loopback, mask: IPv4Address("255.255.255.255")!))
        #else
        publish(LANEndpoint(state: "等待 Wi‑Fi"))
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            Task { @MainActor in
                guard let self, let monitor, self.monitor === monitor else { return }
                let name = path.status == .satisfied ? path.availableInterfaces.first { $0.type == .wifi }?.name : nil
                self.setNetwork(name.flatMap(LANSubnet.interface))
            }
        }
        monitor.start(queue: .main)
        #endif
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        settings = nil
        store = nil
        handle = nil
        closeListener()
        publish(.off)
        didChange = nil
    }

    func endSession() {
        ended = true
        stop()
    }

    private func setNetwork(_ next: LANSubnet?) {
        guard let store, settings != nil else { return }
        if let next, next == network, listener != nil { return }
        closeListener()
        guard let next else {
            publish(LANEndpoint(state: "请连接有 IPv4 地址的 Wi‑Fi"))
            return
        }
        do {
            guard let lease = try LANLease.acquire(store.directory.appending(path: "lan-listener.lock")) else {
                publish(.handoff)
                retryListener(on: next)
                return
            }
            self.lease = lease
            publish(LANEndpoint(state: "正在启动"))
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(next.address), port: port)
            #if !targetEnvironment(simulator) && !BYWAY_LOCAL_TEST
            parameters.requiredInterfaceType = .wifi
            #endif
            let listener = try NWListener(using: parameters)
            self.listener = listener
            network = next
            listener.stateUpdateHandler = { [weak self, weak listener] event in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch event {
                    case .ready:
                        self.publish(LANEndpoint(address: "http://\(next.address):\(self.port.rawValue)", state: "已开启"))
                        self.refreshDiscovery()
                    case .failed(let error):
                        self.listenerFailed(error, on: next)
                    case .waiting(let error):
                        if error == .posix(.EADDRINUSE) {
                            self.listenerFailed(error, on: next)
                        } else {
                            self.stopDiscovery()
                            self.publish(LANEndpoint(state: "等待 Wi‑Fi"))
                        }
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection, from: next)
                }
            }
            listener.start(queue: .main)
        } catch {
            listenerFailed(error, on: next)
        }
    }

    private func listenerFailed(_ error: Error, on network: LANSubnet) {
        Self.logger.error("LAN listener failed: \(error.localizedDescription, privacy: .public)")
        closeListener()
        if (error as? NWError) == .posix(.EADDRINUSE) {
            publish(.handoff)
            retryListener(on: network)
        } else {
            publish(LANEndpoint(state: "监听失败，请重试"))
        }
    }

    private func retryListener(on network: LANSubnet) {
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            self?.setNetwork(network)
        }
    }

    private func refreshDiscovery() {
        guard let network, let address = endpoint.address, let store else { return }
        let enabled = (try? store.readDiscoveryEnabled()) ?? false
        guard discoveryChoice != enabled else { return }
        stopDiscovery()
        discoveryChoice = enabled
        let ipURL = address + "/"
        let label = (try? DeviceIdentityStore.local().read().id)
            .map { "byway-" + $0.replacingOccurrences(of: "-", with: "").prefix(12) }
        guard enabled, network.index != 0, let label else {
            publish(LANEndpoint(address: address, state: endpoint.state,
                                discovery: LANDiscovery(enabled: enabled, status: enabled ? "unavailable" : "off", ipUrl: ipURL)))
            return
        }
        publish(LANEndpoint(address: address, state: endpoint.state,
                            discovery: LANDiscovery(enabled: true, status: "publishing", ipUrl: ipURL)))
        discovery.start(label: label, address: network.address.rawValue, interface: network.index, port: port.rawValue) { [weak self] success in
            guard let self, self.endpoint.address == address, self.discoveryChoice == true else { return }
            let url = success ? "http://\(label).local:\(self.port.rawValue)/" : nil
            self.publish(LANEndpoint(address: address, state: self.endpoint.state,
                                     discovery: LANDiscovery(enabled: true, status: success ? "published" : "unavailable",
                                                             mdnsUrl: url, ipUrl: ipURL)))
        }
    }

    private func stopDiscovery() {
        discovery.stop()
        discoveryChoice = nil
    }

    private struct DiscoveryInput: Decodable { let enabled: Bool }

    private func handleDiscovery(_ request: LANRequest, store: ProfileStore) -> LANResponse {
        do {
            switch request.method {
            case "GET": break
            case "PATCH":
                let input = try request.decode(DiscoveryInput.self, keys: ["enabled"])
                try store.saveDiscoveryEnabled(input.enabled)
                refreshDiscovery()
            default: throw LANFailure(404, "API 路径不存在")
            }
            let enabled = try store.readDiscoveryEnabled()
            return LANResponse(200, endpoint.discovery ?? LANDiscovery(enabled: enabled, status: enabled ? "waiting" : "off"))
        } catch let failure as LANFailure {
            return LANResponse(failure)
        } catch {
            return LANResponse(LANFailure(503, "无法访问局域网发现设置"))
        }
    }

    private func accept(_ connection: NWConnection, from network: LANSubnet) {
        guard let settings, connections.count < 8, network.contains(connection.endpoint) else {
            connection.cancel()
            return
        }
        let id = UUID()
        let address = "\(network.address):\(port.rawValue)"
        let hostname = endpoint.discovery?.mdnsUrl.flatMap { URL(string: $0)?.host }
        let hosts = [address] + (hostname.map { ["\($0):\(port.rawValue)"] } ?? [])
        let stream = LANConnection(connection, authorizedToken: settings.token, hosts: hosts) { [weak self] request in
            guard let self, let store = self.store, let handle = self.handle, self.settings == settings else {
                return LANResponse(LANFailure(503, "局域网控制已暂停"))
            }
            guard (try? store.readLANSettings()) == settings else {
                return LANResponse(LANFailure(401, "控制令牌已失效"))
            }
            if ManagementPage.isAsset(method: request.method, path: request.target) {
                return ManagementPage.response(for: request.target)
            }
            let started = ProcessInfo.processInfo.systemUptime
            let response = request.target == "/v1/discovery" ?
                self.handleDiscovery(request, store: store) : await handle(request)
            if !Task.isCancelled, self.settings == settings,
               let path = request.target.split(separator: "?", maxSplits: 1).first, path != "/v1/diagnostics/api-calls" {
                let duration = ProcessInfo.processInfo.systemUptime - started
                try? store.appendLANCall(LANCall(time: Date(), method: request.method,
                                                path: String(path.prefix(160)), status: response.status,
                                                durationMilliseconds: Int(duration * 1000)))
            }
            return response
        } closed: { [weak self] in
            self?.connections.removeValue(forKey: id)
        }
        connections[id] = stream
        stream.start()
    }

    private func publish(_ endpoint: LANEndpoint) {
        self.endpoint = endpoint
        didChange?(endpoint)
    }

    private func closeListener() {
        stopDiscovery()
        retry?.cancel()
        retry = nil
        listener?.cancel()
        listener = nil
        network = nil
        let closing = Array(connections.values)
        for connection in closing { connection.close() }
        lease = nil
    }
}

private final class LANLease {
    private let descriptor: Int32

    private init(_ descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(_ file: URL) throws -> LANLease? {
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return LANLease(descriptor) }
        let error = POSIXErrorCode(rawValue: errno) ?? .EIO
        close(descriptor)
        if error == .EWOULDBLOCK { return nil }
        throw POSIXError(error)
    }

    deinit { close(descriptor) }
}

private struct LANSubnet: Equatable {
    let address: IPv4Address
    let mask: IPv4Address
    var index: UInt32 = 0

    static func interface(_ name: String) -> Self? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var current = list
        while let entry = current {
            let item = entry.pointee
            current = item.ifa_next
            guard String(cString: item.ifa_name) == name,
                  let endpoint = item.ifa_addr, endpoint.pointee.sa_family == AF_INET,
                  let netmask = item.ifa_netmask else { continue }
            if let address = ipv4(endpoint), let mask = ipv4(netmask) {
                return Self(address: address, mask: mask, index: if_nametoindex(name))
            }
        }
        return nil
    }

    func contains(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint, case let .ipv4(peer) = host else { return false }
        let difference = zip(address.rawValue, peer.rawValue).map { $0 ^ $1 }
        return zip(difference, mask.rawValue).allSatisfy { ($0 & $1) == 0 }
    }

    private static func ipv4(_ pointer: UnsafePointer<sockaddr>) -> IPv4Address? {
        var address = pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        return withUnsafeBytes(of: &address) { IPv4Address(Data($0)) }
    }
}

@MainActor
private final class LANConnection {
    private static let separator = Data([13, 10, 13, 10])
    private static let headerLimit = 8_192
    private static let bodyLimit = 16_384

    private let connection: NWConnection
    private let expectedAuthorization: [UInt8]
    private let hosts: [String]
    private let handle: (LANRequest) async -> LANResponse
    private let closed: () -> Void
    private var received = Data()
    private var timeout: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var finished = false

    init(_ connection: NWConnection, authorizedToken: String, hosts: [String],
         handle: @escaping (LANRequest) async -> LANResponse, closed: @escaping () -> Void) {
        self.connection = connection
        self.hosts = hosts
        expectedAuthorization = Array(("Bearer " + authorizedToken).utf8)
        self.handle = handle
        self.closed = closed
    }

    func start() {
        connection.start(queue: .main)
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) }
            catch { return }
            self?.close()
        }
        read()
    }

    func close() {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        operation?.cancel()
        connection.cancel()
        closed()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] bytes, _, complete, error in
            Task { @MainActor in self?.receive(bytes, complete: complete || error != nil) }
        }
    }

    private func receive(_ bytes: Data?, complete: Bool) {
        guard !finished else { return }
        if let bytes { received.append(bytes) }
        do {
            if let request = try parse() {
                timeout?.cancel()
                operation = Task { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    let response = await self.handle(request)
                    if self.finished {
                        response.afterReply?()
                    } else {
                        self.send(response)
                    }
                }
            } else if complete {
                close()
            } else {
                read()
            }
        } catch let failure as LANFailure {
            send(LANResponse(failure))
        } catch {
            close()
        }
    }

    private func parse() throws -> LANRequest? {
        guard let boundary = received.range(of: Self.separator) else {
            if received.count > Self.headerLimit { throw LANFailure(431, "请求头过大") }
            return nil
        }
        guard boundary.lowerBound <= Self.headerLimit else { throw LANFailure(431, "请求头过大") }
        guard let head = String(data: received[..<boundary.lowerBound], encoding: .utf8) else {
            throw LANFailure(400, "请求头无效")
        }
        let lines = head.components(separatedBy: "\r\n")
        let line = lines[0].split(separator: " ")
        guard line.count == 3, line[2] == "HTTP/1.1", line[1].hasPrefix("/") else {
            throw LANFailure(400, "需要 HTTP/1.1 请求")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw LANFailure(400, "请求头无效") }
            let name = line[..<colon].lowercased()
            guard headers[name] == nil else { throw LANFailure(400, "请求头重复") }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let method = String(line[0]), path = String(line[1])
        let asset = ManagementPage.isAsset(method: method, path: path)
        guard ManagementPage.allowsRequest(method: method, path: path, headers: headers, hosts: hosts, asset: asset) else {
            throw LANFailure(403, "此地址或来源无法访问 Byway API")
        }
        if !asset {
            let actual = Array((headers["authorization"] ?? "").utf8)
            guard actual.count == expectedAuthorization.count,
                  zip(actual, expectedAuthorization).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
                throw LANFailure(401, "控制令牌无效")
            }
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil,
              let length = Int(headers["content-length"] ?? "0"), length >= 0, !asset || length == 0 else {
            throw LANFailure(400, "请求长度无效")
        }
        let configurationUpload = (line[0] == "PUT" && line[1] == "/v1/config/shadowrocket") ||
            (line[0] == "POST" && line[1] == "/v1/config/shadowrocket/preview") ||
            (["POST", "PATCH"].contains(line[0]) && line[1].hasPrefix("/v1/config/routing"))
        let maxBody: Int
        if configurationUpload {
            maxBody = ShadowrocketConfiguration.maxBytes * 2 + 1024
        } else if line[0] == "POST", line[1] == "/v1/import" {
            maxBody = NodeImport.maxBytes * 2 + 1024
        } else if line[0] == "PUT", line[1] == "/v1/routing" {
            maxBody = 1024 * 1024
        } else {
            maxBody = Self.bodyLimit
        }
        guard length <= maxBody else { throw LANFailure(413, "请求正文过大") }
        let end = boundary.upperBound + length
        guard received.count >= end else { return nil }
        guard received.count == end else { throw LANFailure(400, "连接只接受一个请求") }
        return LANRequest(method: String(line[0]), target: String(line[1]), headers: headers,
                          body: received[boundary.upperBound..<end])
    }

    private func send(_ response: LANResponse) {
        connection.send(content: response.encoded, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                self?.close()
                response.afterReply?()
            }
        })
    }
}
