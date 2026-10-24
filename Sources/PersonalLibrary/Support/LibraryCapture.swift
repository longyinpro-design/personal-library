import Foundation
import LibraryCore

extension Notification.Name {
    /// Posted when something outside the window wrote to the library, so the
    /// open window can pick the change up.
    static let libraryDidChangeExternally = Notification.Name("com.longyinpro.personal-library.didChangeExternally")
}

/// Saving shared by App Intents and the menu bar item, so both go through one
/// path. Kept out of the views so it can be tested with a temporary library.
enum LibraryCapture {
    struct Saved: Sendable, Equatable {
        let id: String
        let title: String
    }

    @discardableResult
    static func saveNote(title: String, body: String, tags: [String], in root: URL) async throws -> Saved {
        let repository = try await Task.detached { try LibraryRepository(root: root) }.value
        let trimmedTitle = normalizeTitle(title, body: body)
        let id = try await repository.saveNote(title: trimmedTitle, body: body, kind: .note)
        let cleaned = cleanTags(tags)
        if !cleaned.isEmpty { _ = try await repository.setTags(cleaned, for: [id]) }
        NotificationCenter.default.post(name: .libraryDidChangeExternally, object: nil)
        return Saved(id: id, title: trimmedTitle)
    }

    /// A missing title becomes the first line, so a captured paragraph still has a name.
    static func normalizeTitle(_ title: String, body: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        let first = body.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return first.isEmpty ? "未命名笔记" : String(first.prefix(80))
    }

    static func cleanTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("tag:") }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}
