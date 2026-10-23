import CryptoKit
import Foundation

struct MarkdownAttachmentEntry {
    let reference: String
    var relativePath: String?
    var failure: String?
}

struct PreparedMarkdownImages {
    var entries: [MarkdownAttachmentEntry] = []
    var created: [URL] = []
    var report = MarkdownImageCopyReport()
}

/// Immutable files are published before the SQLite transaction references them.
/// Failed transactions remove only files created by that operation. A crash may
/// leave an unreferenced file; it cannot publish a mapping before its file exists.
struct MarkdownAttachments {
    static let maximumBytes = 32 * 1024 * 1024
    let root: URL

    func managedURL(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "Attachments",
              parts[1].range(of: "^[a-f0-9]{64}\\.(svg|image)$", options: .regularExpression) != nil else {
            throw LibraryError.message("资料库配图路径无效")
        }
        let folder = root.appendingPathComponent("Attachments", isDirectory: true).resolvingSymlinksInPath()
        let url = folder.appendingPathComponent(String(parts[1]))
        guard url.resolvingSymlinksInPath().deletingLastPathComponent().path == folder.path else {
            throw LibraryError.message("配图路径超出资料库")
        }
        return url
    }

    func prepare(text: String, basePath: String?, existing: [MarkdownAttachmentEntry], refresh: Bool) throws -> PreparedMarkdownImages {
        let references = try MarkdownImageSource.references(in: text)
        let prior = Dictionary(uniqueKeysWithValues: existing.map { ($0.reference, $0) })
        let context = MarkdownImageContext(itemID: "copy", basePath: basePath)
        var prepared = PreparedMarkdownImages()
        for reference in references.invalid {
            prepared.entries.append(MarkdownAttachmentEntry(reference: reference, failure: "图片路径无效"))
            prepared.report.references += 1
            prepared.report.failures.append("\(reference)：图片路径无效")
        }
        for reference in references.urls {
            let key = reference.absoluteString
            // Network images remain unsupported and never trigger filesystem or network I/O.
            if let scheme = reference.scheme, !["file", "library-image"].contains(scheme.lowercased()) { continue }
            if let host = reference.host, !["", "localhost"].contains(host.lowercased()) { continue }
            prepared.report.references += 1
            var entry = MarkdownAttachmentEntry(reference: key)
            if let path = prior[key]?.relativePath { entry.relativePath = path }
            do {
                if !refresh, let path = entry.relativePath {
                    try verifySaved(path)
                    prepared.report.reused += 1
                } else {
                    let source = try context.resolve(reference)
                    let data = try readImage(source)
                    let suffix = source.pathExtension.lowercased() == "svg" ? "svg" : "image"
                    let path = "Attachments/\(Self.digest(data)).\(suffix)"
                    let destination = try managedURL(path)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try verifySaved(path)
                        prepared.report.reused += 1
                    } else {
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: destination, options: .atomic)
                        prepared.created.append(destination)
                        prepared.report.copied += 1
                    }
                    entry.relativePath = path
                }
            } catch {
                // Preserve any already archived image if an explicit source refresh fails.
                entry.failure = error.localizedDescription
                prepared.report.failures.append("\(key)：\(error.localizedDescription)")
                if let path = entry.relativePath, (try? verifySaved(path)) != nil {
                    prepared.report.reused += 1
                }
            }
            prepared.entries.append(entry)
        }
        return prepared
    }

    func verifySaved(_ relative: String) throws {
        let url = try managedURL(relative)
        let data = try readImage(url)
        guard Self.digest(data) == url.deletingPathExtension().lastPathComponent else {
            throw LibraryError.message("资料库中的配图校验失败，请保留数据并恢复备份")
        }
    }

    private func readImage(_ source: URL) throws -> Data {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw LibraryError.message("图片地址不是普通文件") }
        guard let size = values.fileSize, size <= Self.maximumBytes else { throw LibraryError.message("图片超过 32 MiB，未复制") }
        let data = try Data(contentsOf: source)
        guard data.count <= Self.maximumBytes else { throw LibraryError.message("图片超过 32 MiB，未复制") }
        return data
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Imported documents keep their full original file even when search text is bounded.
    func fullMarkdown(at url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 200_000_000 else {
            throw LibraryError.message("Markdown 文件超过 200 MB 或不是普通文件")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 200_000_000 else { throw LibraryError.message("Markdown 文件超过 200 MB") }
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]), let text = String(data: data, encoding: .utf16) { return text }
        throw LibraryError.message("无法扫描配图：Markdown 需为 UTF-8 或带 BOM 的 UTF-16")
    }
}
