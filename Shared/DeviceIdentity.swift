import Foundation
#if os(iOS)
import CoreFoundation
import Darwin
import Security
#endif

struct DeviceInfo: Encodable, Sendable {
    let id: String
    let displayName: String
    let type: String
    let modelIdentifier: String?
    let osVersion: String
    let appVersion: String

    var shortCode: String { String(id.prefix(8)).uppercased() }
}

struct DeviceIdentityStore: Sendable {
    let profile: ProfileStore
    let type: String
    let defaultName: String
    let modelIdentifier: String?
    let appVersion: String
    let deviceID: @Sendable () throws -> UUID

    func read() throws -> DeviceInfo {
        let id = try deviceID().uuidString.lowercased()
        let name = try profile.readDeviceName() ?? "\(defaultName)-\(id.prefix(8).uppercased())"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceInfo(id: id, displayName: name, type: type, modelIdentifier: modelIdentifier,
                          osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                          appVersion: appVersion)
    }

    func rename(to value: String) throws -> DeviceInfo {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.unicodeScalars.count),
              name.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.properties.generalCategory {
                  case .control, .lineSeparator, .paragraphSeparator: false
                  default: true
                  }
              }) else {
            throw LANFailure(422, L10n.text("设备名称需要 1 至 80 个字符，且不能包含换行或控制字符"))
        }
        let current = try read()
        if current.displayName != name {
            try profile.saveDeviceName(name)
            #if os(iOS)
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFNotificationName(Self.nameDidChange.rawValue as CFString),
                                                 nil, nil, true)
            #endif
        }
        return DeviceInfo(id: current.id, displayName: name, type: current.type,
                          modelIdentifier: current.modelIdentifier, osVersion: current.osVersion,
                          appVersion: current.appVersion)
    }

    static func local() throws -> Self {
        #if os(iOS)
        guard let group = Bundle.main.object(forInfoDictionaryKey: "BywayAppGroup") as? String else {
            throw LANFailure(503, L10n.text("无法访问设备身份"))
        }
        let model = Self.hardwareModel()
        let type = model.hasPrefix("iPad") ? "ipad" : model.hasPrefix("iPhone") ? "iphone" : "ios"
        let name = type == "ipad" ? "iPad" : type == "iphone" ? "iPhone" : "Byway"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return Self(profile: try ProfileStore.open(), type: type, defaultName: name,
                    modelIdentifier: model.isEmpty ? nil : model, appVersion: version,
                    deviceID: { try keychainID(group: group) })
        #elseif os(macOS)
        var system = utsname()
        let model = uname(&system) == 0
            ? withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            : ""
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return Self(profile: try ProfileStore.open(), type: "mac", defaultName: "Mac",
                    modelIdentifier: model.isEmpty ? nil : model, appVersion: version,
                    deviceID: {
                        let key = "BywayDeviceID"
                        if let saved = UserDefaults.standard.string(forKey: key),
                           let id = UUID(uuidString: saved) { return id }
                        let id = UUID()
                        UserDefaults.standard.set(id.uuidString, forKey: key)
                        return id
                    })
        #endif
    }

    static let nameDidChange = Notification.Name("cn.splaz.byway.device-name-changed")

    static func observeNameChanges() {
        #if os(iOS)
        _ = observeDarwinNameChanges
        #endif
    }

    #if os(iOS)
    private static let observeDarwinNameChanges: Void = {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            NotificationCenter.default.post(name: nameDidChange, object: nil)
        }, nameDidChange.rawValue as CFString, nil, .deliverImmediately)
    }()

    private static func hardwareModel() -> String {
        #if targetEnvironment(simulator)
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return model }
        #endif
        var system = utsname()
        guard uname(&system) == 0 else { return "" }
        return withUnsafeBytes(of: system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func keychainID(group: String) throws -> UUID {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: group,
            kSecAttrService as String: "cn.splaz.byway.device-identity",
            kSecAttrAccount as String: "id"
        ]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        func existing() throws -> UUID? {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data,
                  let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) else {
                throw LANFailure(503, L10n.text("无法读取设备身份"))
            }
            return id
        }

        if let id = try existing() { return id }
        let id = UUID()
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = Data(id.uuidString.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return id }
        // The App and VPN extension can both see the item as missing at first launch.
        if status == errSecDuplicateItem, let saved = try existing() { return saved }
        throw LANFailure(503, L10n.text("无法保存设备身份"))
    }
    #endif
}
