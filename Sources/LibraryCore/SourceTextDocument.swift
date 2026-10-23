import Foundation

public struct SourcePosition: Equatable, Sendable {
    public let line: Int
    public let column: Int?

    public init(line: Int, column: Int? = nil) {
        self.line = line; self.column = column
    }

    /// Only literal suffix colons are syntax; percent-encoded colons stay filenames.
    static func separating(from original: URL) throws -> (URL, SourcePosition?) {
        var url = original
        let protocols: Set<String> = ["http", "https", "javascript", "data", "mailto", "tel", "sms",
            "smb", "ssh", "ftp", "ftps", "sftp", "afp", "nfs", "vscode", "vscode-insiders", "xcode"]
        if let scheme = url.scheme, scheme.lowercased() != "file", !protocols.contains(scheme.lowercased()),
           let relative = URL(string: "./" + url.absoluteString) {
            // Foundation interprets bare `file.swift:12` and `README:12` as
            // schemes. A numeric suffix is local filename syntax; explicit
            // protocols retain their normal rejection/browser behavior.
            url = relative
        }
        guard url.scheme == nil || url.scheme?.lowercased() == "file",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return (original, nil) }
        let path = components.percentEncodedPath
        let regex = try NSRegularExpression(pattern: "^(.+?):([0-9]+)(?::([0-9]+))?$")
        let full = NSRange(path.startIndex..<path.endIndex, in: path)
        guard let match = regex.firstMatch(in: path, range: full),
              let base = Range(match.range(at: 1), in: path),
              let lineRange = Range(match.range(at: 2), in: path) else { return (original, nil) }
        let columnRange = Range(match.range(at: 3), in: path)
        guard let line = Int(path[lineRange]), line > 0 else { throw LibraryError.message("行号必须是从 1 开始的有效整数。") }
        let column = columnRange.flatMap { Int(path[$0]) }
        guard columnRange == nil || (column ?? 0) > 0 else { throw LibraryError.message("列号必须是从 1 开始的有效整数。") }
        components.percentEncodedPath = String(path[base])
        guard let target = components.url else { throw LibraryError.message("链接地址无效") }
        return (target, SourcePosition(line: line, column: column))
    }
}

public struct SourceTextDocument: Sendable {
    public let text: String
    public let lineCount: Int
    public let selection: NSRange
    public let lineRange: NSRange
    public static let maximumBytes = 8 * 1024 * 1024

    public static func load(_ url: URL, at position: SourcePosition) throws -> SourceTextDocument {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw LibraryError.message("行号跳转需要普通文本文件。")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw LibraryError.message("行号预览最多支持 8 MiB 的文本文件。") }
        }
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xFE, 0xFF]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        else if data.starts(with: [0xEF, 0xBB, 0xBF]) { text = String(data: data.dropFirst(3), encoding: .utf8) }
        else { text = String(data: data, encoding: .utf8) }
        guard let text, !text.contains("\0") else { throw LibraryError.message("此文件不是支持的 UTF-8 或带 BOM 的 UTF-16 文本。") }
        return try SourceTextDocument(text: text, at: position)
    }

    public init(text: String, at position: SourcePosition) throws {
        let nsText = text as NSString
        var ranges: [NSRange] = []
        var offset = 0
        while offset < nsText.length {
            var start = 0, end = 0, contentsEnd = 0
            nsText.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
            ranges.append(NSRange(location: start, length: contentsEnd - start))
            offset = end
            if end == nsText.length, contentsEnd < end { ranges.append(NSRange(location: end, length: 0)) }
        }
        if ranges.isEmpty { ranges = [NSRange(location: 0, length: 0)] }
        guard position.line > 0, position.line <= ranges.count else {
            throw LibraryError.message("请求第 \(position.line) 行，但此文件共有 \(ranges.count) 行。")
        }
        let line = ranges[position.line - 1]
        var selection = line
        if let column = position.column {
            let value = nsText.substring(with: line)
            guard column > 0, column <= value.count + 1 else { throw LibraryError.message("第 \(position.line) 行没有第 \(column) 列。") }
            let index = value.index(value.startIndex, offsetBy: column - 1)
            let length = index == value.endIndex ? 0 : String(value[index]).utf16.count
            selection = NSRange(location: line.location + value[..<index].utf16.count, length: length)
        }
        self.text = text; self.lineCount = ranges.count
        self.selection = selection; self.lineRange = line
    }
}
