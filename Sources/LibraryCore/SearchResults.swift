import Foundation

/// Scope and filters applied before matching, so FTS only ranks the visible slice.
public struct LibrarySearchFilter: Sendable, Equatable {
    public var kind: ItemKind?
    public var collectionID: String?
    public var inboxOnly: Bool
    public var favoritesOnly: Bool
    public var recentLimit: Int?

    public init(kind: ItemKind? = nil, collectionID: String? = nil, inboxOnly: Bool = false, favoritesOnly: Bool = false, recentLimit: Int? = nil) {
        self.kind = kind
        self.collectionID = collectionID
        self.inboxOnly = inboxOnly
        self.favoritesOnly = favoritesOnly
        self.recentLimit = recentLimit
    }
}

/// Immutable output for one query. Views read this without searching the document bodies again.
public struct LibrarySearchResults: Sendable {
    public let query: String
    public let items: [LibraryItem]
    public let presentations: [String: LibrarySearchPresentation]

    public init(query: String = "", items: [LibraryItem] = [], presentations: [String: LibrarySearchPresentation] = [:]) {
        self.query = query
        self.items = items
        self.presentations = presentations
    }
}

public struct LibrarySearchPresentation: Sendable {
    public let excerpt: String
    public let matchingExcerpt: String?
}

extension LibrarySearch {
    /// Run on a worker task. The Foundation user-level search rules match `matches(_:query:)`.
    /// Each term searches a document body at most once, including snippet location.
    public static func search(_ items: [LibraryItem], query: String) throws -> LibrarySearchResults {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var matches: [LibraryItem] = []
        var presentations: [String: LibrarySearchPresentation] = [:]
        for item in items {
            try Task.checkCancellation()
            var firstBodyMatch: Range<String.Index>?
            var matchesAll = true
            for term in terms {
                try Task.checkCancellation()
                let titleMatches = item.title.localizedStandardContains(term)
                // Once the first body hit is known, a title hit needs no further body scan.
                if titleMatches && firstBodyMatch != nil { continue }
                let bodyMatch = item.text.localizedStandardRange(of: term)
                if !titleMatches && bodyMatch == nil { matchesAll = false; break }
                if firstBodyMatch == nil { firstBodyMatch = bodyMatch }
            }
            guard matchesAll else { continue }
            matches.append(item)
            presentations[item.id] = LibrarySearchPresentation(
                excerpt: excerpt(item.text, match: firstBodyMatch, limit: 180),
                matchingExcerpt: firstBodyMatch.map { excerpt(item.text, match: $0, limit: 330) }
            )
        }
        try Task.checkCancellation()
        return LibrarySearchResults(query: query, items: matches, presentations: presentations)
    }

    static func excerpt(_ text: String, match: Range<String.Index>?, limit: Int) -> String {
        let start = match.map { text.index($0.lowerBound, offsetBy: -35, limitedBy: text.startIndex) ?? text.startIndex } ?? text.startIndex
        let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end].replacingOccurrences(of: "\n", with: " ") + (end < text.endIndex ? "…" : "")
    }
}
