import Foundation

enum L10n {
    private static let language = Bundle.main.preferredLocalizations.first ?? "en"
    private static let translations = load(language)
    private static let english = language == "en" ? translations : load("en")
    private static let argument = #/\{([0-9]+)\}/#

    static func text(_ source: String, _ arguments: Any...) -> String {
        let template = language == "zh-Hans" ? source : (translations[source] ?? english[source] ?? source)
        guard !arguments.isEmpty else { return template }
        return template.replacing(argument) { match in
            guard let index = Int(match.1), arguments.indices.contains(index) else {
                return String(match.0)
            }
            return String(describing: arguments[index])
        }
    }

    private static func load(_ language: String) -> [String: String] {
        // Simplified Chinese is the source language.
        guard language != "zh-Hans" else { return [:] }
        guard let url = Bundle.main.url(forResource: "byway-\(language)", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return entries
    }
}
