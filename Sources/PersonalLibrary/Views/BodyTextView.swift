import AppKit
import SwiftUI

/// A single `Text` with a multi-megabyte body blocks the main thread for seconds
/// when SwiftUI lays it out, especially with text selection enabled. Split the
/// body into paragraph-sized chunks and let `LazyVStack` lay out only the chunks
/// that are actually visible.
struct BodyTextView: View {
    let text: String
    var monospaced = false
    var highlight: String = ""
    var onChunkVisible: ((Int) -> Void)? = nil
    var onChunkHidden: ((Int) -> Void)? = nil
    @StateObject private var model = BodyTextModel()

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.chunks(for: text)) { chunk in
                Text(highlighted(chunk.text))
                    .font(monospaced ? .system(size: 13, design: .monospaced) : .system(size: 14))
                    .lineSpacing(monospaced ? 5 : 8)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(MarkdownScrollTarget.bodyChunk(chunk.id))
                    .onAppear { onChunkVisible?(chunk.id) }
                    .onDisappear { onChunkHidden?(chunk.id) }
            }
        }
    }

    private func highlighted(_ text: Substring) -> AttributedString {
        guard !highlight.isEmpty else { return AttributedString(text) }
        let string = String(text)
        let attributed = NSMutableAttributedString(string: string)
        let ns = string as NSString
        var search = NSRange(location: 0, length: ns.length)
        var count = 0
        while search.length > 0, count < 500 {
            let found = ns.range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive], range: search)
            guard found.location != NSNotFound else { break }
            attributed.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: found)
            attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: found)
            let next = found.location + max(found.length, 1)
            search = NSRange(location: next, length: ns.length - next)
            count += 1
        }
        return AttributedString(attributed)
    }
}

/// Chunking is memoized for the lifetime of one reader view, so store updates
/// (search progress, selection) never rescan the body on the main thread.
@MainActor
final class BodyTextModel: ObservableObject {
    private var source: String?
    private var cached: [BodyTextChunk] = []

    func chunks(for text: String) -> [BodyTextChunk] {
        if source == text { return cached }
        let chunks = BodyTextChunk.split(text)
        source = text
        cached = chunks
        return chunks
    }
}

struct BodyTextChunk: Identifiable {
    let id: Int
    let text: Substring

    static let maximumLength = 4_000

    /// Cut at the last newline inside the window so paragraphs stay together and
    /// no character is dropped. A hard cut is only used for very long lines.
    static func split(_ text: String, limit: Int = maximumLength) -> [BodyTextChunk] {
        guard limit > 0, !text.isEmpty else { return [] }
        var chunks: [BodyTextChunk] = []
        var start = text.startIndex
        var index = 0
        while start < text.endIndex {
            let target = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            var end = target
            var next = target
            if target < text.endIndex, let newline = text[start..<target].lastIndex(of: "\n"), newline > start {
                end = newline
                next = text.index(after: newline)
            }
            chunks.append(BodyTextChunk(id: index, text: text[start..<end]))
            index += 1
            start = next
        }
        return chunks
    }
}
