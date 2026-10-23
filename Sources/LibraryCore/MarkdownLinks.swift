import Foundation

public enum MarkdownLinkTarget: Equatable, Sendable {
    case web(URL)
    case item(id: String, fragment: String?)
    case localFile(URL, fragment: String?)
    case sourceFile(URL, position: SourcePosition, itemID: String?)
}

/// Resolve against recorded source identities, never against a guessed basename.
/// Lexical paths deliberately survive a missing or moved original directory.
public enum MarkdownLinks {
    public static func opensInBrowser(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host ?? "").isEmpty
    }

    public static func resolve(_ url: URL, from item: LibraryItem, items: [LibraryItem], root: URL) throws -> MarkdownLinkTarget {
        if opensInBrowser(url) { return .web(url) }
        let (url, position) = try SourcePosition.separating(from: url)
        guard url.scheme == nil || url.scheme?.lowercased() == "file",
              [nil, "", "localhost"].contains(url.host?.lowercased()),
              url.query == nil, url.user == nil, url.password == nil, url.port == nil else {
            throw LibraryError.message("此链接类型暂不支持。可打开网页、本机文件和 Markdown 标题链接。")
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let decodedPath = components.percentEncodedPath.removingPercentEncoding else { throw LibraryError.message("链接地址无效") }
        let fragment = components.percentEncodedFragment?.removingPercentEncoding
        guard components.percentEncodedFragment == nil || fragment != nil,
              !url.isFileURL || decodedPath.hasPrefix("/") else { throw LibraryError.message("链接地址无效") }
        guard !decodedPath.contains("\0"), !(fragment ?? "").contains("\0") else { throw LibraryError.message("链接地址无效") }
        guard position == nil || fragment == nil || fragment == "" else { throw LibraryError.message("行号和标题锚点不能同时使用。") }
        if url.scheme == nil, decodedPath.isEmpty { return .item(id: item.id, fragment: fragment) }

        let paths: [String]
        if url.isFileURL || decodedPath.hasPrefix("/") {
            paths = [URL(fileURLWithPath: decodedPath).standardizedFileURL.path]
        } else {
            var bases = Set(item.sourcePaths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
            if bases.isEmpty, let base = item.imageBasePath { bases.insert(base) }
            guard !bases.isEmpty else { throw LibraryError.message("这份资料没有原文目录。请重新导入原文；笔记可通过「图片目录」指定相对链接的目录。") }
            paths = bases.sorted().map { base in
                URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(decodedPath).standardizedFileURL.path
            }
        }
        let targets = Set(paths)
        let matches = items.filter { candidate in
            if candidate.sourcePaths.contains(where: targets.contains) { return true }
            guard let relative = candidate.relativePath else { return false }
            return targets.contains(root.appendingPathComponent("Files").appendingPathComponent(relative).standardizedFileURL.path)
        }

        // The imported AMI handbooks use a generated HTML index as their TOC.
        // Its doc IDs are the relative Markdown path with each non-word character
        // replaced by '-'. Scope the match to that exact index directory/language.
        if position == nil, let fragment, fragment.hasPrefix("doc-") {
            var aliases: [MarkdownLinkTarget] = []
            for path in paths where URL(fileURLWithPath: path).lastPathComponent == "index.html" {
                let base = URL(fileURLWithPath: path).deletingLastPathComponent().path + "/"
                for candidate in items where candidate.usesMarkdown {
                    for source in candidate.sourcePaths where source.hasPrefix(base) {
                        let relative = String(source.dropFirst(base.count))
                        let stem = (relative as NSString).deletingPathExtension
                        let alias = "doc-" + stem.replacingOccurrences(of: "[^\\w-]", with: "-", options: .regularExpression)
                        if fragment == alias { aliases.append(.item(id: candidate.id, fragment: nil)) }
                        else if fragment.hasPrefix(alias + "-") {
                            aliases.append(.item(id: candidate.id, fragment: String(fragment.dropFirst(alias.count + 1))))
                        }
                    }
                }
            }
            // A document's ID can also be a prefix of a longer document ID.
            let exact = aliases.filter { if case .item(_, nil) = $0 { return true }; return false }
            if !exact.isEmpty { return try unique(exact) }
            if !aliases.isEmpty { return try unique(aliases) }
        }
        if !matches.isEmpty {
            return try unique(matches.map { candidate in
                if let position, let relative = candidate.relativePath {
                    return .sourceFile(root.appendingPathComponent("Files").appendingPathComponent(relative), position: position, itemID: candidate.id)
                }
                return .item(id: candidate.id, fragment: fragment)
            })
        }
        guard paths.count == 1, let path = paths.first else {
            throw LibraryError.message("这份资料有多个来源目录，链接目标不明确。请导入对应文件后再打开。")
        }
        let localURL = URL(fileURLWithPath: path)
        if let position { return .sourceFile(localURL, position: position, itemID: nil) }
        return .localFile(localURL, fragment: fragment)
    }

    private static func unique(_ targets: [MarkdownLinkTarget]) throws -> MarkdownLinkTarget {
        let distinct = targets.reduce(into: [MarkdownLinkTarget]()) { if !$0.contains($1) { $0.append($1) } }
        guard distinct.count == 1, let target = distinct.first else {
            throw LibraryError.message("链接对应多份已导入资料，无法确定版本。请在资料列表中选择所需副本。")
        }
        return target
    }
}
