import Foundation

enum ManagementPage {
    static let policy = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src data:; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"

    private static let resources = [
        "/": ("management", "html", "text/html"),
        "/management.css": ("management", "css", "text/css"),
        "/management.js": ("management", "js", "text/javascript")
    ]

    static func isAsset(method: String, path: String) -> Bool {
        method == "GET" && resources[path] != nil
    }

    static func allowsRequest(method: String, path: String, headers: [String: String], hosts: [String], asset: Bool) -> Bool {
        let origin = headers["origin"]
        let site = headers["sec-fetch-site"]
        if !asset && origin == nil && site == nil { return true }
        guard let host = headers["host"], hosts.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }),
              origin == nil || origin == "http://\(host)",
              site == nil || site == "same-origin" || (asset && site == "none") else { return false }
        if asset { return true }
        switch (method, path) {
        case ("GET", "/v1/device"), ("GET", "/v1/status"), ("GET", "/v1/nodes"), ("GET", "/v1/config/routing"),
             ("GET", "/v1/discovery"), ("PATCH", "/v1/discovery"), ("PATCH", "/v1/device"): return true
        default: return false
        }
    }

    static func response(for path: String) -> LANResponse {
        guard let (name, ext, contentType) = resources[path] else {
            return LANResponse(LANFailure(404, L10n.text("页面不存在")))
        }
        #if BYWAY_LOCAL_TEST
        let url: URL? = URL(fileURLWithPath: "Shared/Web", isDirectory: true).appending(path: "\(name).\(ext)")
        #else
        let url = Bundle.main.url(forResource: name, withExtension: ext)
        #endif
        guard let url, let body = try? Data(contentsOf: url) else {
            return LANResponse(LANFailure(503, L10n.text("无法读取管理网页")))
        }
        return LANResponse(webAsset: body, contentType: contentType)
    }
}
