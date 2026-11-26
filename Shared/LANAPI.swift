import Foundation

struct LANFailure: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }

    init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }

    static let nodeNotFound = Self(404, L10n.text("节点不存在"))
}

struct LANRequest: Codable, Sendable {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data

    func decode<T: Decodable>(_ type: T.Type, keys: Set<String>) throws -> T {
        let mediaType = headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
        guard mediaType?.lowercased() == "application/json" else {
            throw LANFailure(415, L10n.text("请求需要 application/json"))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              !object.isEmpty, Set(object.keys).isSubset(of: keys), object.values.allSatisfy({ !($0 is NSNull) }) else {
            throw LANFailure(400, L10n.text("请求必须是 JSON 对象，且只能包含支持的字段"))
        }
        do { return try JSONDecoder().decode(type, from: body) }
        catch { throw LANFailure(400, L10n.text("请求字段类型或值无效")) }
    }
}

struct LANResponse: Sendable {
    let status: Int
    let body: Data
    private let contentType: String
    private let webAsset: Bool
    let afterReply: (@Sendable () -> Void)?

    init(_ status: Int, _ payload: some Encodable, afterReply: (@Sendable () -> Void)? = nil) {
        self.status = status
        self.body = (try? JSONEncoder().encode(payload)) ?? Data()
        self.contentType = "application/json"
        self.webAsset = false
        self.afterReply = afterReply
    }

    init(webAsset body: Data, contentType: String) {
        self.status = 200
        self.body = body
        self.contentType = contentType
        self.webAsset = true
        self.afterReply = nil
    }

    init(_ error: LANFailure) { self.init(error.status, ["error": error.message]) }

    var encoded: Data {
        let text = "HTTP/1.1 \(status) \(reason)\r\n" +
            "Content-Type: \(contentType); charset=utf-8\r\n" +
            "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        let security = webAsset ?
            "Content-Security-Policy: \(ManagementPage.policy)\r\nX-Content-Type-Options: nosniff\r\n" +
            "Referrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\n" : ""
        return Data((text + security + "\r\n").utf8) + body
    }

    private var reason: String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 422: "Unprocessable Content"
        case 431: "Request Header Fields Too Large"
        case 503: "Service Unavailable"
        default: "Internal Server Error"
        }
    }
}

struct LANAPI: Sendable {
    let backend: any LANBackend
    var deviceStore: @Sendable () throws -> DeviceIdentityStore = { try DeviceIdentityStore.local() }

    func handle(_ request: LANRequest) async -> LANResponse {
        do {
            try Task.checkCancellation()
            let segments = request.target.split(separator: "/", omittingEmptySubsequences: false)
            switch (request.method, request.target) {
            case ("GET", "/v1/device"):
                return LANResponse(200, try deviceStore().read())
            case ("PATCH", "/v1/device"):
                let input = try request.decode(DeviceNameInput.self, keys: ["displayName"])
                return LANResponse(200, try deviceStore().rename(to: input.displayName))
            case ("GET", "/v1/status"):
                let snapshot = try await backend.lanSnapshot()
                let decision = snapshot.profile.globalRoutingSettings.decision(on: snapshot.routingNetwork ?? .other)
                return LANResponse(200, Status(connected: snapshot.connected, selectedNodeID: snapshot.activeID,
                                               configuration: snapshot.profile.routingSettings,
                                               deviceInfo: try? deviceStore().read(),
                                               usesImportedConfiguration: decision.mode == .rules &&
                                                   snapshot.profile.importedConfiguration?.enabled == true))
            case ("GET", "/v1/nodes"):
                return LANResponse(200, try await backend.lanSnapshot().profile.nodes.map(Node.init))
            case ("POST", "/v1/nodes"):
                let input = try request.decode(NodeInput.self, keys: ["link", "name"])
                guard let link = input.link else { throw LANFailure(400, L10n.text("请提供节点链接")) }
                let receipt = try await backend.lanEdit(.create(link: link, name: input.name))
                return LANResponse(201, receipt.node.map(Node.init))
            case ("GET", "/v1/config"):
                return LANResponse(200, try await backend.lanSnapshot().profile.routingSettings)
            case ("PATCH", "/v1/config"):
                let patch = try request.decode(LANRoutingPatch.self,
                                               keys: ["defaultRoute", "dnsServer", "bypassPrivateNetworks", "directDomains"])
                let receipt = try await backend.lanEdit(.changeRouting(patch))
                return LANResponse(200, receipt.routing)
            case ("GET", "/v1/config/dns"):
                return LANResponse(200, try await backend.lanSnapshot().profile.dnsSettings)
            case ("PUT", "/v1/config/dns"):
                let input = try request.decode(DNSUpdate.self, keys: ["dnsSettings"])
                let receipt = try await backend.lanEdit(.changeDNS(input.dnsSettings))
                return LANResponse(200, receipt.dnsSettings)
            case ("GET", "/v1/config/shadowrocket"):
                let snapshot = try await backend.lanSnapshot()
                return LANResponse(200, try snapshot.profile.importedConfiguration?.report())
            case ("POST", "/v1/config/shadowrocket/preview"):
                let input = try request.decode(ConfigurationInput.self, keys: ["text"])
                return LANResponse(200, try ImportedConfiguration(text: input.text, enabled: false).report())
            case ("PUT", "/v1/config/shadowrocket"):
                let input = try request.decode(ConfigurationInput.self, keys: ["text", "acceptWarnings"])
                let receipt = try await backend.lanEdit(.importConfiguration(text: input.text,
                                                                          acceptWarnings: input.acceptWarnings == true))
                return LANResponse(200, receipt.importedConfiguration)
            case ("PATCH", "/v1/config/shadowrocket"):
                let patch = try request.decode(ConfigurationActivation.self, keys: ["enabled"])
                let receipt = try await backend.lanEdit(.useImportedConfiguration(patch.enabled))
                return LANResponse(200, receipt.importedConfiguration)
            case ("GET", "/v1/routing"):
                let snapshot = try await backend.lanSnapshot()
                let settings = snapshot.profile.globalRoutingSettings
                return LANResponse(200, RoutingStatus(settings: settings, network: snapshot.routingNetwork,
                                                      effective: settings.decision(on: snapshot.routingNetwork ?? .other)))
            case ("PUT", "/v1/routing"):
                let input = try request.decode(RoutingUpdate.self, keys: ["globalRouting"])
                let receipt = try await backend.lanEdit(.changeGlobalRouting(input.globalRouting))
                return LANResponse(200, receipt.globalRouting)
            default:
                if segments.count == 4 || segments.count == 5,
                   segments[0].isEmpty, segments[1] == "v1", segments[2] == "nodes",
                   let id = UUID(uuidString: String(segments[3])) {
                    return try await nodeRoute(request, id: id, action: segments.count == 5 ? String(segments[4]) : nil)
                }
                return try await MobileAPI(backend: backend).handle(request)
            }
        } catch let error as LANFailure {
            return LANResponse(error)
        } catch let error as BywayError {
            return LANResponse(LANFailure(422, error.localizedDescription))
        } catch is CancellationError {
            return LANResponse(LANFailure(503, L10n.text("局域网控制已暂停")))
        } catch {
            return LANResponse(LANFailure(500, L10n.text("操作失败，请查询设备状态")))
        }
    }

    private func nodeRoute(_ request: LANRequest, id: UUID, action: String?) async throws -> LANResponse {
        switch (request.method, action) {
        case ("GET", nil):
            let snapshot = try await backend.lanSnapshot()
            guard let node = snapshot.profile.nodes.first(where: { $0.id == id }) else { throw LANFailure.nodeNotFound }
            return LANResponse(200, Node(node))
        case ("PATCH", nil):
            let input = try request.decode(NodeInput.self, keys: ["link", "name"])
            guard input.link != nil || input.name != nil else { throw LANFailure(400, L10n.text("请提供待修改的字段")) }
            let receipt = try await backend.lanEdit(.update(id: id, link: input.link, name: input.name))
            return LANResponse(200, receipt.node.map(Node.init))
        case ("DELETE", nil):
            let receipt = try await backend.lanEdit(.delete(id))
            return LANResponse(200, ["deleted": id], afterReply: receipt.afterReply)
        case ("POST", "probe"):
            return LANResponse(200, try await backend.lanNodeCommand(.probe, id: id))
        case ("POST", "select"):
            return LANResponse(200, try await backend.lanNodeCommand(.select, id: id))
        case ("GET", "share"):
            return try await MobileAPI(backend: backend).shareNode(id)
        default:
            throw LANFailure(404, L10n.text("API 路径不存在"))
        }
    }

    private struct Node: Encodable {
        let id: UUID
        let name: String
        let host: String
        let port: Int

        init(_ node: ProxyNode) { (id, name, host, port) = (node.id, node.name, node.host, node.port) }
    }

    private struct NodeInput: Decodable {
        let link: String?
        let name: String?
    }

    private struct ConfigurationInput: Decodable {
        let text: String
        let acceptWarnings: Bool?
    }

    private struct ConfigurationActivation: Decodable {
        let enabled: Bool
    }

    private struct DeviceNameInput: Decodable { let displayName: String }

    private struct Status: Encodable {
        let connected: Bool
        let selectedNodeID: UUID?
        let configuration: ProxyRouting
        let deviceInfo: DeviceInfo?
        let usesImportedConfiguration: Bool
    }

    private struct RoutingStatus: Encodable {
        let settings: GlobalRouting
        let network: RoutingNetwork?
        let effective: RoutingDecision
    }
}
