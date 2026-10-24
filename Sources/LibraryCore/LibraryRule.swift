import Foundation

/// A deterministic import rule: when a file name contains `match`, the new item
/// goes into `collection` and gets `tags`. Rules run in order, first hit wins,
/// so the list itself is the priority.
public struct LibraryRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Substring looked for in the file name, ignoring case and width.
    public var match: String
    /// Collection name; created when missing. Empty means "leave it alone".
    public var collection: String?
    public var tags: [String]
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, match: String, collection: String? = nil,
                tags: [String] = [], isEnabled: Bool = true) {
        self.id = id
        self.match = match
        self.collection = collection
        self.tags = tags
        self.isEnabled = isEnabled
    }

    /// True when the rule has something to do and something to match on.
    public var isUseful: Bool {
        !match.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (collection?.isEmpty == false || !tags.isEmpty)
    }
}

public enum LibraryRules {
    /// First enabled rule whose `match` appears in the file name.
    public static func match(for fileName: String, in rules: [LibraryRule]) -> LibraryRule? {
        let name = fold(fileName)
        for rule in rules where rule.isEnabled {
            let needle = fold(rule.match)
            guard !needle.isEmpty else { continue }
            if name.contains(needle) { return rule }
        }
        return nil
    }

    /// Case and full/half width are presentation details; matching should not
    /// care whether the file came from macOS, Windows or a phone.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum LibraryRuleStore {
    public static let fileName = "rules.json"

    public static func load(from root: URL) -> [LibraryRule] {
        let url = root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode([LibraryRule].self, from: data) else { return [] }
        return rules
    }

    public static func save(_ rules: [LibraryRule], in root: URL) {
        let url = root.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(rules) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
