import Foundation
import cmark_gfm
import cmark_gfm_extensions

public struct MarkdownSection: Sendable {
    public let markdown: String
}

/// A heading in document order. `section` is the lazy-rendering section that
/// contains the heading; a heading nested in a list or quote shares its
/// containing section.
public struct MarkdownHeading: Identifiable, Sendable, Hashable {
    public let level: Int
    public let title: String
    public let anchor: String
    public let section: Int

    public var id: String { anchor }

    public init(level: Int, title: String, anchor: String, section: Int) {
        self.level = level
        self.title = title
        self.anchor = anchor
        self.section = section
    }
}

public struct MarkdownStructure: Sendable {
    public let sections: [MarkdownSection]
    public let anchors: [String: Int]
    public let headings: [MarkdownHeading]

    /// Parse the whole document first so reference definitions survive sectioning.
    /// A heading inside a list/quote lands at its containing section.
    public static func parse(_ source: String) throws -> MarkdownStructure {
        let text = MarkdownImageSource.normalizingImageURLs(MarkdownImageSource.renderable(source), includingLinks: true)
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { throw LibraryError.message("无法解析 Markdown") }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            if let syntax = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, syntax) }
        }
        cmark_parser_feed(parser, text, text.utf8.count)
        guard let document = cmark_parser_finish(parser) else { throw LibraryError.message("无法解析 Markdown") }
        defer { cmark_node_free(document) }
        var sections: [String] = []
        var anchors: [String: Int] = [:]
        var headings: [MarkdownHeading] = []
        var aliases: [String: Set<Int>] = [:]
        var used = Set<String>()
        var current = cmark_node_first_child(document)
        while let node = current {
            try Task.checkCancellation()
            // Keep ordinary blocks together; start a new section at headings and
            // containers with nested headings so their targets stay close by.
            let nodeHeadings = headingInfos(node)
            if sections.isEmpty || !nodeHeadings.isEmpty { sections.append("") }
            let index = sections.count - 1
            for heading in nodeHeadings {
                let base = slug(heading.title)
                var value = base
                var suffix = 0
                while used.contains(value) { suffix += 1; value = "\(base)-\(suffix)" }
                used.insert(value); anchors[value] = index
                headings.append(MarkdownHeading(level: heading.level, title: heading.title, anchor: value, section: index))
                let legacy = heading.title.components(separatedBy: .alphanumerics.inverted).map { $0.lowercased() }.joined(separator: "-")
                aliases[legacy, default: []].insert(index)
                aliases[heading.title, default: []].insert(index)
            }
            guard let rendered = cmark_render_commonmark(node, CMARK_OPT_DEFAULT, 0) else { throw LibraryError.message("无法排版 Markdown 章节") }
            sections[index] += String(cString: rendered) + "\n"
            free(rendered)
            current = cmark_node_next(node)
        }
        for (name, indices) in aliases where anchors[name] == nil && indices.count == 1 { anchors[name] = indices.first! }
        return MarkdownStructure(sections: sections.map { MarkdownSection(markdown: $0) }, anchors: anchors, headings: headings)
    }

    private static func headingInfos(_ root: UnsafeMutablePointer<cmark_node>) -> [(level: Int, title: String)] {
        guard let iterator = cmark_iter_new(root) else { return [] }
        defer { cmark_iter_free(iterator) }
        var headings: [(level: Int, title: String)] = []
        while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
            guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator),
                  cmark_node_get_type(node) == CMARK_NODE_HEADING else { continue }
            headings.append((Int(cmark_node_get_heading_level(node)), plainText(node)))
        }
        return headings
    }

    private static func plainText(_ node: UnsafeMutablePointer<cmark_node>) -> String {
        let type = cmark_node_get_type(node)
        if [CMARK_NODE_TEXT, CMARK_NODE_CODE].contains(type), let text = cmark_node_get_literal(node) { return String(cString: text) }
        if [CMARK_NODE_SOFTBREAK, CMARK_NODE_LINEBREAK].contains(type) { return " " }
        var result = ""
        var current = cmark_node_first_child(node)
        while let child = current { result += plainText(child); current = cmark_node_next(child) }
        return result
    }

    private static func slug(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(CharacterSet(charactersIn: "_-"))
        return title.lowercased().unicodeScalars.reduce(into: "") { value, scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { value += "-" }
            else if allowed.contains(scalar) { value.unicodeScalars.append(scalar) }
        }
    }
}
