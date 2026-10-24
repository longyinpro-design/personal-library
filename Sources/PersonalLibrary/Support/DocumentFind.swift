import Foundation

struct DocumentMatch: Identifiable, Equatable, Sendable {
    let id: Int
    let anchor: MarkdownScrollTarget
    let snippet: String
}

/// Finds literal, case-insensitive occurrences inside the reader's source.
/// Markdown matches are section-level because the rendered view cannot expose
/// text ranges; plain text matches point at the lazy chunk that contains them.
enum DocumentFind {
    static let maximumMatches = 500

    static func matches(in text: String, query: String, markdownSections: [String]? = nil) -> [DocumentMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        if let sections = markdownSections {
            guard !sections.isEmpty else { return [] }
            return collect(sections.enumerated().map { (String($0.element), $0.offset) },
                           needle: needle,
                           anchor: { .section($0) })
        }
        let chunks = BodyTextChunk.split(text)
        return collect(chunks.map { (String($0.text), $0.id) }, needle: needle, anchor: { .bodyChunk($0) })
    }

    private static func collect(_ sources: [(String, Int)],
                                needle: String,
                                anchor: @escaping (Int) -> MarkdownScrollTarget) -> [DocumentMatch] {
        var matches: [DocumentMatch] = []
        for (source, index) in sources {
            var search = source.startIndex..<source.endIndex
            while matches.count < maximumMatches,
                  let found = source.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: search) {
                matches.append(DocumentMatch(id: matches.count, anchor: anchor(index), snippet: snippet(source, around: found)))
                guard found.upperBound < source.endIndex else { break }
                search = found.upperBound..<source.endIndex
            }
            if matches.count >= maximumMatches { break }
        }
        return matches
    }

    private static func snippet(_ source: String, around range: Range<String.Index>) -> String {
        let start = source.index(range.lowerBound, offsetBy: -36, limitedBy: source.startIndex) ?? source.startIndex
        let end = source.index(range.upperBound, offsetBy: 72, limitedBy: source.endIndex) ?? source.endIndex
        var value = String(source[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if start > source.startIndex { value = "…" + value }
        if end < source.endIndex { value += "…" }
        return value
    }
}
