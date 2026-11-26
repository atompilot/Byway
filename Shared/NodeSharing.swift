import Foundation
import CryptoKit
import zlib

extension ProxyNode {
    func shareLink() throws -> String {
        let outbound = try outboundConfiguration
        func text(_ key: String) -> String { outbound[key] as? String ?? "" }
        let tls = outbound["tls"] as? [String: Any] ?? [:]
        let reality = tls["reality"] as? [String: Any]
        let transport = outbound["transport"] as? [String: Any] ?? [:]
        let security = reality != nil ? "reality" : (tls["enabled"] as? Bool == true ? "tls" : "")
        let fingerprint = (tls["utls"] as? [String: Any])?["fingerprint"] as? String ?? ""
        let serverName = tls["server_name"] as? String ?? ""
        let alpn = (tls["alpn"] as? [String])?.joined(separator: ",") ?? ""
        let network = transport["type"] as? String ?? "tcp"
        let wsHost = (transport["headers"] as? [String: String])?["Host"] ?? ""
        let wsPath = transport["path"] as? String ?? ""
        var url = URLComponents()
        url.host = host.contains(":") ? "[\(host)]" : host
        url.port = port
        url.fragment = name
        var fields: [(String, String)] = []
        switch text("type") {
        case "vless":
            url.scheme = "vless"
            url.user = text("uuid")
            fields = [("encryption", "none"), ("type", network), ("security", security), ("flow", text("flow")),
                      ("sni", serverName), ("alpn", alpn), ("fp", fingerprint), ("host", wsHost), ("path", wsPath),
                      ("pbk", reality?["public_key"] as? String ?? ""), ("sid", reality?["short_id"] as? String ?? "")]
        case "vmess":
            let contents = ["v": "2", "ps": name, "add": host, "port": String(port), "id": text("uuid"),
                            "aid": String(outbound["alter_id"] as? Int ?? 0), "scy": text("security"), "net": network,
                            "type": "none", "host": wsHost, "path": wsPath, "tls": security, "sni": serverName, "fp": fingerprint, "alpn": alpn]
            return "vmess://" + (try JSONEncoder().encode(contents)).base64EncodedString()
        case "shadowsocks":
            url.scheme = "ss"
            if text("method").hasPrefix("2022-") {
                url.user = text("method")
                url.password = text("password")
            } else {
                url.user = NodeShare.base64URL(Data("\(text("method")):\(text("password"))".utf8))
            }
            if !text("plugin").isEmpty {
                let options = text("plugin_opts")
                fields = [("plugin", text("plugin") + (options.isEmpty ? "" : ";" + options))]
            }
        case "socks":
            url.scheme = "socks5"
            url.user = outbound["username"] as? String
            url.password = outbound["password"] as? String
        default:
            throw BywayError.message(L10n.text("此节点不能生成分享链接"))
        }
        if !fields.isEmpty { url.queryItems = fields.filter { !$0.1.isEmpty }.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let link = url.string else { throw BywayError.message(L10n.text("无法生成节点链接")) }
        return link
    }
}

enum NodeShare {
    static let groupPrefix = "byway-group://"
    static let partPrefix = "byway-part://"
    static let maxCodeBytes = 2 * 1024 * 1024
    static let partSize = 1450

    private struct GroupPayload: Codable {
        let Name: String
        let Links: [String]
    }

    static func group(name: String, nodes: [ProxyNode]) throws -> String {
        guard !nodes.isEmpty else { throw BywayError.message(L10n.text("节点组为空")) }
        let payload = try JSONEncoder().encode(GroupPayload(Name: name, Links: nodes.map { try $0.shareLink() }))
        guard payload.count <= NodeImport.maxBytes else { throw BywayError.message(L10n.text("节点组超过分享上限")) }
        let value = groupPrefix + base64URL(try gzip(payload, compress: true))
        guard value.utf8.count <= maxCodeBytes else { throw BywayError.message(L10n.text("节点组超过分享上限")) }
        return value
    }

    static func readGroup(_ value: String) throws -> (String, NodeImport) {
        guard value.lowercased().hasPrefix(groupPrefix), value.utf8.count <= maxCodeBytes,
              let bytes = NodeImport.decodeBase64(String(value.dropFirst(groupPrefix.count))) else {
            throw BywayError.message(L10n.text("无法读取节点组分享码"))
        }
        let payload = try JSONDecoder().decode(GroupPayload.self, from: gzip(bytes, compress: false))
        guard !payload.Links.isEmpty, payload.Links.count <= NodeSubscription.maxNodes,
              payload.Links.allSatisfy({ !$0.contains(where: \.isNewline) }) else {
            throw BywayError.message(L10n.text("节点组分享码无效"))
        }
        let result = try NodeImport(payload.Links.joined(separator: "\n"))
        guard result.skipped == 0 else { throw BywayError.message(L10n.text("节点组包含不支持的节点")) }
        return (payload.Name, result)
    }

    static func subscription(_ value: NodeSubscription) -> String {
        var fragment = URLComponents()
        fragment.fragment = value.name
        return "sub://" + base64URL(Data(value.address.absoluteString.utf8)) + "#" + (fragment.percentEncodedFragment ?? "")
    }

    static func parts(_ value: String) -> [String] {
        guard value.count > partSize else { return [value] }
        let characters = Array(value)
        let hash = checksum(value)
        let count = (characters.count + partSize - 1) / partSize
        return (0..<count).map { index in
            let offset = index * partSize
            let content = String(characters[offset..<min(offset + partSize, characters.count)])
            return "\(partPrefix)\(hash)/\(index + 1)/\(count)/\(content)"
        }
    }

    static func checksum(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func gzip(_ input: Data, compress: Bool) throws -> Data {
        var stream = z_stream()
        let initialized = compress
            ? deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            : inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw BywayError.message(L10n.text("无法处理压缩数据")) }
        defer { if compress { deflateEnd(&stream) } else { inflateEnd(&stream) } }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let capacity = buffer.count
        return try input.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = UInt32(input.count)
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { output in
                    stream.next_out = output.baseAddress
                    stream.avail_out = UInt32(capacity)
                    return compress ? deflate(&stream, Z_FINISH) : inflate(&stream, Z_NO_FLUSH)
                }
                let written = capacity - Int(stream.avail_out)
                guard result.count + written <= NodeImport.maxBytes,
                      status == Z_OK || status == Z_STREAM_END else { throw BywayError.message(L10n.text("压缩数据损坏或过大")) }
                result.append(contentsOf: buffer.prefix(written))
                if status == Z_STREAM_END { return result }
            }
        }
    }
}

struct NodeShareParts {
    private var hash = ""
    private var fragments: [Int: String] = [:]
    private var count = 0
    var progress: String { L10n.text("已读取 {0} / {1} 张", fragments.count, count) }

    mutating func accept(_ value: String) throws -> String? {
        guard value.lowercased().hasPrefix(NodeShare.partPrefix) else { return value }
        let fields = value.dropFirst(NodeShare.partPrefix.count).split(separator: "/", maxSplits: 3)
        guard fields.count == 4, fields[0].count == 16, fields[0].allSatisfy(\.isHexDigit),
              let index = Int(fields[1]), let total = Int(fields[2]), (2...1500).contains(total),
              (1...total).contains(index), (1...NodeShare.partSize).contains(fields[3].utf8.count) else {
            throw BywayError.message(L10n.text("分段二维码无效"))
        }
        if hash != fields[0].lowercased() || count != total {
            hash = fields[0].lowercased()
            count = total
            fragments = [:]
        }
        fragments[index] = String(fields[3])
        guard fragments.count == count else { return nil }
        let full = (1...count).compactMap { fragments[$0] }.joined()
        guard full.utf8.count <= NodeShare.maxCodeBytes, NodeShare.checksum(full) == hash else {
            fragments = [:]
            throw BywayError.message(L10n.text("整组二维码校验失败，请重新扫描"))
        }
        return full
    }
}
