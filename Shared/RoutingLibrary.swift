import Foundation

struct SavedRoutingConfiguration: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var text: String
}

struct RoutingLibrary: Codable, Equatable, Sendable {
    var configurations: [SavedRoutingConfiguration] = []
    var activeID: UUID?

    // An existing profile has one implicit slot. Keep its identifier stable until first write.
    private static let legacyID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    static func migrating(_ previous: ImportedConfiguration?) -> Self {
        guard let previous else { return Self() }
        return Self(configurations: [.init(id: legacyID, name: "已导入的配置", text: previous.text)],
                    activeID: previous.enabled ? legacyID : nil)
    }

    func configuration(_ id: UUID) throws -> SavedRoutingConfiguration {
        guard let configuration = configurations.first(where: { $0.id == id }) else {
            throw LANFailure(404, "分流配置不存在")
        }
        return configuration
    }

    var legacyProjection: ImportedConfiguration? {
        let selected = configurations.first(where: { $0.id == activeID })
        return (selected ?? configurations.first).map { ImportedConfiguration(text: $0.text, enabled: selected != nil) }
    }
}

enum RoutingLibraryEdit: Sendable {
    case save(id: UUID?, name: String?, text: String?, acceptWarnings: Bool, activate: Bool)
    case activate(UUID?)
    case delete(UUID)
    case insertRule(UUID, String)
}

extension BywayProfile {
    var savedRouting: RoutingLibrary { routingLibrary ?? .migrating(importedConfiguration) }

    mutating func editRoutingLibrary(_ edit: RoutingLibraryEdit) throws {
        var library = savedRouting
        switch edit {
        case let .save(id, name, text, acceptWarnings, activate):
            let existing = try id.map(library.configuration)
            guard let text = text ?? existing?.text else { throw LANFailure(400, "请提供分流配置文本") }
            let name = (name ?? existing?.name ?? "Shadowrocket 配置").trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...80).contains(name.count),
                  name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw LANFailure(422, "配置名称需要 1 至 80 个字符")
            }
            let importDocument = try RoutingImportDocument(text)
            guard existing?.text == text || acceptWarnings || (importDocument.warnings + importDocument.parsed.warnings).isEmpty else {
                throw LANFailure(422, "配置含有兼容提示，请先预览并确认")
            }
            let record = SavedRoutingConfiguration(id: id ?? UUID(), name: name, text: text)
            if let index = library.configurations.firstIndex(where: { $0.id == record.id }) {
                library.configurations[index] = record
            } else {
                guard library.configurations.count < 32 else { throw LANFailure(422, "最多可保存 32 份分流配置") }
                library.configurations.append(record)
            }
            if activate { library.activeID = record.id }
        case .activate(let id):
            if let id { _ = try library.configuration(id) }
            library.activeID = id
        case .delete(let id):
            _ = try library.configuration(id)
            library.configurations.removeAll { $0.id == id }
            if library.activeID == id { library.activeID = nil }
        case let .insertRule(id, line):
            let configuration = try library.configuration(id)
            let updated = try ShadowrocketConfiguration.inserting(line, into: configuration.text)
            try editRoutingLibrary(.save(id: id, name: nil, text: updated, acceptWarnings: true, activate: false))
            return
        }
        routingLibrary = library
        importedConfiguration = library.legacyProjection
    }
}
