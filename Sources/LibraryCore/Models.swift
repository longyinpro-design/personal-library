import Foundation

public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case document, note, thought, image, other
    public var label: String {
        switch self {
        case .document: return "文档"
        case .note: return "笔记"
        case .thought: return "随笔"
        case .image: return "图片"
        case .other: return "其他"
        }
    }
    public var symbol: String {
        switch self {
        case .document: return "doc.text"
        case .note: return "note.text"
        case .thought: return "square.and.pencil"
        case .image: return "photo"
        case .other: return "doc"
        }
    }
}

public struct LibraryItem: Identifiable, Sendable {
    public let id: String
    public var title: String
    public let kind: ItemKind
    public let relativePath: String?
    public var text: String
    public let extractionNote: String?
    public let byteCount: Int64
    public let createdAt: Date
    public var updatedAt: Date
    public var collectionID: String?
    public var favorite: Bool
    public var imageBasePath: String? = nil
    public var imageAttachments: [String: URL] = [:]
    public var imageAttachmentIssues: [String] = []
    public var sourcePaths: [String] = []
    /// A short body prefix for list rows. Snapshots load this instead of the full text.
    public var preview: String = ""
    /// True when the stored body has any non-whitespace character. Computed by
    /// SQLite during the snapshot, so filters never need the full text.
    public var hasBody: Bool = true
    /// True when the body contains an http(s) link. Also computed by the snapshot.
    public var hasLinks: Bool = false
    /// False until the reader asks for this item's body.
    public var textLoaded: Bool = true
    /// Set while the item sits in the trash. Trashed items stay on disk for 30 days.
    public var deletedAt: Date? = nil
    public var isTrashed: Bool { deletedAt != nil }
    public var isEditable: Bool { kind == .note || kind == .thought }
    public var usesMarkdown: Bool { isEditable || ["MD", "MARKDOWN"].contains(fileExtension) }
    public var fileExtension: String {
        relativePath.map { URL(fileURLWithPath: $0).pathExtension.uppercased() } ?? (kind == .note ? "NOTE" : "MEMO")
    }
}

public struct LibraryCollection: Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct LibraryActivity: Identifiable, Sendable {
    public let id: String
    public let message: String
    public let date: Date

    public init(id: String, message: String, date: Date) {
        self.id = id
        self.message = message
        self.date = date
    }
}

public struct LibrarySnapshot: Sendable {
    public var items: [LibraryItem] = []
    /// Items in the trash, newest deletion first. Kept apart so counts and
    /// totals never include them.
    public var trashed: [LibraryItem] = []
    public var collections: [LibraryCollection] = []
    public var activities: [LibraryActivity] = []
    public init() {}
}

public struct ImportReport: Sendable {
    public var importedIDs: [String] = []
    public var skipped: [String] = []
    public var failures: [String] = []
    public var warnings: [String] = []
}

public struct LibraryDeletionReport: Sendable {
    public var deleted = 0
    public var warnings: [String] = []
    public init() {}
}

public struct MarkdownImageCopyReport: Sendable {
    public var references = 0
    public var copied = 0
    public var reused = 0
    public var failures: [String] = []
    public var saved: Int { copied + reused }
    public var summary: String {
        "已保存 \(saved) 个配图引用" + (failures.isEmpty ? "" : "，\(failures.count) 个未能更新")
    }
}

public enum LibraryRetention {
    /// Trashed items stay recoverable this many days before the launch purge
    /// removes their rows and managed copies.
    public static let trashDays = 30
    public static let trash: TimeInterval = TimeInterval(trashDays) * 24 * 60 * 60
}

public enum LibraryError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        if case let .message(message) = self { return message }
        return nil
    }
}

public enum LibrarySearch {
    public static func matches(_ item: LibraryItem, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { term in
            item.title.localizedStandardContains(String(term)) || item.text.localizedStandardContains(String(term))
        }
    }

    public static func excerpt(_ text: String, query: String, limit: Int = 180) -> String {
        let match = query.split(whereSeparator: \.isWhitespace).lazy.compactMap {
            text.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive])
        }.first
        return excerpt(text, match: match, limit: limit)
    }
}
