import Foundation
import cmark_gfm
import cmark_gfm_extensions

public struct MarkdownImageContext: Hashable, Sendable {
    public let itemID: String
    public let basePath: String?
    public var revision: Int = 0
    public let attachments: [String: URL]

    public init(itemID: String, basePath: String?, revision: Int = 0, attachments: [String: URL] = [:]) {
        self.itemID = itemID; self.basePath = basePath; self.revision = revision; self.attachments = attachments
    }

    public func resolve(_ url: URL) throws -> URL {
        // A published attachment never falls back to a potentially changed source.
        if let saved = attachments[url.absoluteString] { return saved }
        if url.scheme == "library-image" {
            // The existing AMI handbooks keep images/ beside menus/ or businessFlows/.
            let name = String(url.absoluteString.dropFirst("library-image:".count)).removingPercentEncoding ?? ""
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), ![".", ".."].contains(name) else {
                throw MarkdownImageError.message("图片文件名无效")
            }
            guard let basePath else { throw MarkdownImageError.missingBase }
            var directory = URL(fileURLWithPath: basePath, isDirectory: true)
            for _ in 0...3 {
                let candidate = directory.appendingPathComponent("images").appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                directory.deleteLastPathComponent()
            }
            throw MarkdownImageError.message("未找到手册配图：\(name)")
        }

        let resolved: URL
        if url.scheme == nil {
            guard url.host == nil else { throw MarkdownImageError.remote }
            if url.relativeString.hasPrefix("/") {
                resolved = URL(fileURLWithPath: url.path)
            } else {
                guard let basePath else { throw MarkdownImageError.missingBase }
                guard let value = URL(string: url.relativeString, relativeTo: URL(fileURLWithPath: basePath, isDirectory: true)) else {
                    throw MarkdownImageError.invalidPath
                }
                resolved = value.absoluteURL
            }
        } else {
            resolved = url
        }
        guard resolved.isFileURL, [nil, "", "localhost"].contains(resolved.host?.lowercased()) else {
            throw MarkdownImageError.remote
        }
        guard !resolved.path.contains("\0") else { throw MarkdownImageError.invalidPath }
        return resolved.standardizedFileURL.resolvingSymlinksInPath()
    }
}

public enum MarkdownImageError: LocalizedError {
    case message(String), missingBase, remote, invalidPath
    public var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .missingBase: return "相对图片缺少目录，请点击「图片目录」选择原文所在文件夹。"
        case .remote: return "远程图片不会自动加载"
        case .invalidPath: return "图片路径无效"
        }
    }
}

public struct MarkdownImageReferences: Sendable {
    public var urls: [URL] = []
    public var invalid: [String] = []
}

public enum MarkdownImageSource {
    /// Match the exact image destinations delivered by the reading renderer.
    public static func references(in source: String) throws -> MarkdownImageReferences {
        let text = normalizingImageURLs(renderable(source))
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { throw MarkdownImageError.message("无法解析配图引用") }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            if let syntax = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, syntax) }
        }
        cmark_parser_feed(parser, text, text.utf8.count)
        guard let document = cmark_parser_finish(parser) else { throw MarkdownImageError.message("无法解析配图引用") }
        defer { cmark_node_free(document) }
        guard let iterator = cmark_iter_new(document) else { throw MarkdownImageError.message("无法遍历配图引用") }
        defer { cmark_iter_free(iterator) }
        var references = MarkdownImageReferences()
        var seen = Set<String>()
        while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
            guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER,
                  let node = cmark_iter_get_node(iterator), cmark_node_get_type(node) == CMARK_NODE_IMAGE,
                  let pointer = cmark_node_get_url(node) else { continue }
            let value = String(cString: pointer)
            guard seen.insert(value).inserted else { continue }
            if let url = URL(string: value, encodingInvalidCharacters: false) { references.urls.append(url) }
            else { references.invalid.append(value) }
        }
        return references
    }

    /// Foundation auto-encoding escapes existing percent sequences when an image
    /// destination also contains Unicode. Normalize the parser's original URL first.
    public static func normalizingImageURLs(_ source: String, includingLinks: Bool = false) -> String {
        guard includingLinks || source.contains("![") else { return source }
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return source }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            if let syntax = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, syntax) }
        }
        cmark_parser_feed(parser, source, source.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return source }
        defer { cmark_node_free(document) }
        guard let iterator = cmark_iter_new(document) else { return source }
        defer { cmark_iter_free(iterator) }
        var changed = false
        let allowed = CharacterSet.urlFragmentAllowed.union(CharacterSet(charactersIn: "%#[]"))
        while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
            guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER,
                  let node = cmark_iter_get_node(iterator),
                  (cmark_node_get_type(node) == CMARK_NODE_IMAGE || (includingLinks && cmark_node_get_type(node) == CMARK_NODE_LINK)),
                  let pointer = cmark_node_get_url(node) else { continue }
            let source = String(cString: pointer)
            // Preserve valid escapes while encoding a literal percent in a filename.
            let escaped = source.replacingOccurrences(of: "%(?![0-9a-fA-F]{2})", with: "%25", options: .regularExpression)
            guard let encoded = escaped.addingPercentEncoding(withAllowedCharacters: allowed), source != encoded,
                  URL(string: encoded, encodingInvalidCharacters: false) != nil else { continue }
            cmark_node_set_url(node, encoded)
            changed = true
        }
        guard changed, let rendered = cmark_render_commonmark(document, CMARK_OPT_DEFAULT, 0) else { return source }
        defer { free(rendered) }
        return String(cString: rendered)
    }

    /// Recognize the handbooks' standalone marker using the existing CommonMark parser.
    /// Code blocks, inline code and ordinary Markdown remain byte-for-byte unchanged.
    public static func renderable(_ source: String) -> String {
        guard source.contains("/imgstart:"),
              let document = cmark_parse_document(source, source.utf8.count, CMARK_OPT_DEFAULT) else { return source }
        defer { cmark_node_free(document) }
        guard let iterator = cmark_iter_new(document) else { return source }
        defer { cmark_iter_free(iterator) }
        var lines = source.components(separatedBy: "\n")
        while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
            guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER,
                  let node = cmark_iter_get_node(iterator), cmark_node_get_type(node) == CMARK_NODE_PARAGRAPH,
                  cmark_node_get_start_line(node) == cmark_node_get_end_line(node),
                  let child = cmark_node_first_child(node), cmark_node_next(child) == nil,
                  cmark_node_get_type(child) == CMARK_NODE_TEXT,
                  let literal = cmark_node_get_literal(child) else { continue }
            let text = String(cString: literal)
            guard text.hasPrefix("/imgstart:"), text.hasSuffix(":imgend/") else { continue }
            let name = String(text.dropFirst(10).dropLast(8))
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
                  let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { continue }
            let index = Int(cmark_node_get_start_line(node)) - 1
            guard lines.indices.contains(index), lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == text else { continue }
            lines[index] = "![手册配图](library-image:\(encoded))"
        }
        return lines.joined(separator: "\n")
    }
}
