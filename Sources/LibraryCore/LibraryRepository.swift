import CryptoKit
import Foundation
import os

public actor LibraryRepository {
    public nonisolated let root: URL
    private let database: Database
    private let files: URL
    private let scanMinimumBytes: Int64
    private var images: MarkdownAttachments { MarkdownAttachments(root: root) }

    public init(root: URL) throws {
        try self.init(root: root, scanMinimumBytes: Self.defaultScanMinimumBytes)
    }

    /// `scanMinimumBytes` lets tests exercise the split scan on a small library.
    init(root: URL, scanMinimumBytes: Int64) throws {
        self.root = root
        self.scanMinimumBytes = scanMinimumBytes
        self.files = root.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Attachments", isDirectory: true), withIntermediateDirectories: true)
        self.database = try Database(url: root.appendingPathComponent("library.sqlite"))
    }

    public func snapshot() throws -> LibrarySnapshot {
        var snapshot = LibrarySnapshot()
        let imageRows = Dictionary(grouping: try database.rows("SELECT * FROM markdown_images ORDER BY reference"), by: { $0["item_id"]! })
        let sourceRows = Dictionary(grouping: try database.rows("SELECT * FROM item_sources ORDER BY path"), by: { $0["item_id"]! })
        let tagRows = Dictionary(grouping: try database.rows("SELECT item_tags.item_id AS item_id, tags.name AS name FROM item_tags JOIN tags ON tags.id = item_tags.tag_id ORDER BY tags.name COLLATE NOCASE"), by: { $0["item_id"]! })
        let columns = """
            id, title, kind, relative_path, substr(body, 1, 240) AS preview,
                   extraction_note, byte_count, created_at, updated_at, collection_id,
                   favorite, image_base_path, deleted_at,
                   length(trim(body)) > 0 AS has_body,
                   instr(body, '](http') > 0 OR instr(body, '<http') > 0 AS has_links
            """
        snapshot.items = try database.rows("SELECT \(columns) FROM items WHERE deleted_at IS NULL ORDER BY updated_at DESC, id")
            .map { try item(from: $0, imageRows: imageRows, sourceRows: sourceRows, tagRows: tagRows) }
        snapshot.trashed = try database.rows("SELECT \(columns) FROM items WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC, id")
            .map { try item(from: $0, imageRows: imageRows, sourceRows: sourceRows, tagRows: tagRows) }
        snapshot.tags = try database.rows("""
            SELECT tags.id AS id, tags.name AS name, count(items.id) AS count
            FROM tags
            LEFT JOIN item_tags ON item_tags.tag_id = tags.id
            LEFT JOIN items ON items.id = item_tags.item_id AND items.deleted_at IS NULL
            GROUP BY tags.id, tags.name
            ORDER BY tags.name COLLATE NOCASE
            """).map { LibraryTag(id: $0["id"]!, name: $0["name"]!, count: Int($0["count"] ?? "") ?? 0) }
        snapshot.collections = try database.rows("SELECT * FROM collections ORDER BY name COLLATE NOCASE").map {
            LibraryCollection(id: $0["id"]!, name: $0["name"]!)
        }
        snapshot.activities = try database.rows("SELECT * FROM activities ORDER BY date DESC LIMIT 200").map {
            LibraryActivity(id: $0["id"]!, message: $0["message"]!, date: Date(timeIntervalSince1970: Double($0["date"]!)!))
        }
        return snapshot
    }

    private func item(from row: [String: String], imageRows: [String: [[String: String]]],
                      sourceRows: [String: [[String: String]]], tagRows: [String: [[String: String]]]) throws -> LibraryItem {
        guard let id = row["id"], let title = row["title"], let rawKind = row["kind"], let kind = ItemKind(rawValue: rawKind),
              let created = Double(row["created_at"] ?? ""), let updated = Double(row["updated_at"] ?? ""),
              let size = Int64(row["byte_count"] ?? "") else { throw LibraryError.message("资料库记录格式损坏，请保留数据目录并恢复备份。") }
        let attached = try (imageRows[id] ?? []).reduce(into: [String: URL]()) { result, image in
            if let path = image["relative_path"] { result[image["reference"]!] = try images.managedURL(path) }
        }
        let issues = (imageRows[id] ?? []).compactMap { image in image["failure"].map { "\(image["reference"]!)：\($0)" } }
        return LibraryItem(id: id, title: title, kind: kind, relativePath: row["relative_path"], text: "", extractionNote: row["extraction_note"], byteCount: size, createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: updated), collectionID: row["collection_id"], favorite: row["favorite"] == "1", imageBasePath: row["image_base_path"], imageAttachments: attached, imageAttachmentIssues: issues, sourcePaths: (sourceRows[id] ?? []).compactMap { $0["path"] }, preview: row["preview"] ?? "", hasBody: row["has_body"] == "1", hasLinks: row["has_links"] == "1", textLoaded: false, tags: (tagRows[id] ?? []).compactMap { $0["name"] }, deletedAt: row["deleted_at"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) })
    }

    /// One file the user asked to import, with the digest that was read off disk
    /// while the import sheet was open.
    public struct PendingImport: Sendable, Identifiable {
        public let id: String
        public let url: URL
        public let fingerprint: String
        /// Copies already in the library with the same bytes.
        public let existing: [LibraryItem]
        /// The same file was picked twice in one import.
        public let repeatedInBatch: Bool

        public var name: String { url.lastPathComponent }
        public var isDuplicate: Bool { !existing.isEmpty || repeatedInBatch }
    }

    public struct ImportPreview: Sendable {
        public var pending: [PendingImport] = []
        public var failures: [String] = []
        public var duplicates: [PendingImport] { pending.filter(\.isDuplicate) }
        public var hasDuplicates: Bool { !duplicates.isEmpty }
        public var existingCopyCount: Int { duplicates.reduce(0) { $0 + $1.existing.count } }
    }

    /// Hashes every file and looks for copies already in the library, so the app
    /// can ask before copying anything.
    public func previewImport(_ urls: [URL]) throws -> ImportPreview {
        var preview = ImportPreview()
        var seen: [String: Int] = [:]
        for source in urls {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { throw LibraryError.message("请选择普通文件，文件夹请先选择其中的文件") }
                guard (values.fileSize ?? 0) <= 200_000_000 else { throw LibraryError.message("第一版支持单文件不超过 200 MB") }
                let fingerprint = try FileFingerprint.sha256(of: source)
                let copies = seen[fingerprint, default: 0]
                seen[fingerprint] = copies + 1
                let existing = try items(matchingFingerprint: fingerprint)
                preview.pending.append(PendingImport(id: UUID().uuidString, url: source, fingerprint: fingerprint,
                                                     existing: existing, repeatedInBatch: copies > 0))
            } catch {
                preview.failures.append("\(source.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return preview
    }

    /// Copies the files that passed the preview. Duplicates are skipped or copied
    /// again depending on what the user picked in the prompt.
    public func importFiles(_ preview: ImportPreview, skippingDuplicates: Bool) throws -> ImportReport {
        var report = ImportReport()
        report.failures += preview.failures
        for entry in preview.pending {
            let source = entry.url
            if skippingDuplicates, entry.isDuplicate {
                report.skipped.append(source.lastPathComponent)
                continue
            }
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let id = UUID().uuidString
            let ext = source.pathExtension.filter { $0.isLetter || $0.isNumber }.prefix(16)
            let relativePath = id + (ext.isEmpty ? "" : ".\(ext)")
            let destination = files.appendingPathComponent(relativePath)
            do {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { throw LibraryError.message("请选择普通文件，文件夹请先选择其中的文件") }
                guard (values.fileSize ?? 0) <= 200_000_000 else { throw LibraryError.message("第一版支持单文件不超过 200 MB") }
                try FileManager.default.copyItem(at: source, to: destination)
                let extraction = TextExtractor.extract(destination, temporaryDirectory: root)
                let now = String(Date().timeIntervalSince1970)
                let imageBase = ["md", "markdown"].contains(source.pathExtension.lowercased()) ? source.deletingLastPathComponent().standardizedFileURL.path : nil
                var prepared = PreparedMarkdownImages()
                if let imageBase {
                    do { prepared = try images.prepare(text: images.fullMarkdown(at: destination), basePath: imageBase, existing: [], refresh: false) }
                    catch { report.warnings.append("\(source.lastPathComponent)：\(error.localizedDescription)") }
                }
                try publishImages(prepared, id: id) {
                    try database.execute("INSERT INTO items (id,title,kind,relative_path,body,extraction_note,byte_count,created_at,updated_at,image_base_path,fingerprint,ocr_version) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", [id, source.lastPathComponent, extraction.kind.rawValue, relativePath, extraction.text, extraction.note, String(values.fileSize ?? 0), now, now, imageBase, entry.fingerprint, extraction.usedOCR ? "1" : "0"])
                    try database.execute("INSERT INTO item_sources (item_id,path) VALUES (?,?)", [id, source.standardizedFileURL.path])
                    try record("导入了「\(source.lastPathComponent)」")
                }
                report.importedIDs.append(id)
                report.warnings += prepared.report.failures.map { "\(source.lastPathComponent)：\($0)" }
            } catch {
                var message = "\(source.lastPathComponent)：\(error.localizedDescription)"
                if FileManager.default.fileExists(atPath: destination.path) {
                    do { try FileManager.default.removeItem(at: destination) }
                    catch { message += "；导入副本清理失败，保留于 \(destination.path)" }
                }
                report.failures.append(message)
            }
        }
        return report
    }

    public func importFiles(_ urls: [URL]) throws -> ImportReport {
        try importFiles(previewImport(urls), skippingDuplicates: false)
    }

    // MARK: - Library packages

    /// Writes one item as a `.plib` folder inside `directory`. Everything is built
    /// in a temporary folder first, so a failure never leaves half a package.
    public func exportPackage(id: String, to directory: URL) throws -> URL {
        guard let row = try database.rows("SELECT * FROM items WHERE id = ?", [id]).first,
              let title = row["title"], let kind = row["kind"] else {
            throw LibraryPackageError.missingItem
        }
        let destination = directory
            .appendingPathComponent(LibraryPackage.packageName(title))
            .appendingPathExtension(LibraryPackage.fileExtension)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LibraryPackageError.destinationExists(destination.lastPathComponent)
        }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("plib-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let contentName = try writePackageContent(row: row, into: staging)
            var attachments: [LibraryPackage.Metadata.Attachment] = []
            let imageRows = try database.rows("""
                SELECT reference, relative_path FROM markdown_images
                WHERE item_id = ? AND relative_path IS NOT NULL ORDER BY reference
                """, [id])
            if !imageRows.isEmpty {
                let folder = staging.appendingPathComponent(LibraryPackage.attachmentsFolder, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for image in imageRows {
                    guard let reference = image["reference"], let relative = image["relative_path"] else { continue }
                    let source = try images.managedURL(relative)
                    guard FileManager.default.fileExists(atPath: source.path) else { continue }
                    try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
                    attachments.append(.init(reference: reference,
                                             file: LibraryPackage.attachmentsFolder + "/" + source.lastPathComponent))
                }
            }
            let tags = try database.rows("""
                SELECT tags.name AS name FROM item_tags JOIN tags ON tags.id = item_tags.tag_id
                WHERE item_tags.item_id = ? ORDER BY tags.name COLLATE NOCASE
                """, [id]).compactMap { $0["name"] }
            let metadata = LibraryPackage.Metadata(
                id: id, title: title, kind: kind,
                createdAt: Date(timeIntervalSince1970: Double(row["created_at"] ?? "") ?? 0),
                updatedAt: Date(timeIntervalSince1970: Double(row["updated_at"] ?? "") ?? 0),
                tags: tags,
                originalPath: try database.rows("SELECT path FROM item_sources WHERE item_id = ? ORDER BY path LIMIT 1", [id]).first?["path"],
                contentName: contentName,
                attachments: attachments)
            let data = try LibraryPackage.encoder().encode(metadata)
            try data.write(to: staging.appendingPathComponent(LibraryPackage.metadataName), options: .atomic)
            try FileManager.default.moveItem(at: staging, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Markdown goes out as `content.md`; anything else leaves as a copy of the
    /// original bytes, which keeps PDFs and images usable outside the app.
    private func writePackageContent(row: [String: String], into directory: URL) throws -> String {
        let relative = row["relative_path"]
        let suffix = relative.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
        if relative == nil || ["md", "markdown"].contains(suffix) {
            let body = row["body"] ?? ""
            try body.write(to: directory.appendingPathComponent(LibraryPackage.markdownName), atomically: true, encoding: .utf8)
            return LibraryPackage.markdownName
        }
        guard let relative else { throw LibraryPackageError.missingFile(row["title"] ?? "") }
        let source = files.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: source.path) else { throw LibraryPackageError.missingFile(relative) }
        let name = suffix.isEmpty ? "content" : "content." + suffix
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
        return name
    }

    /// Reads a `.plib` back into the library without the source machine. The
    /// package id is not reused: a second import is a second item, like any file.
    public func importPackage(from url: URL) throws -> LibraryItem {
        let packageURL = LibraryPackage.packageDirectory(for: url)
        let metadataURL = packageURL.appendingPathComponent(LibraryPackage.metadataName)
        guard let data = try? Data(contentsOf: metadataURL) else { throw LibraryPackageError.notAPackage }
        let metadata: LibraryPackage.Metadata
        do { metadata = try LibraryPackage.decoder().decode(LibraryPackage.Metadata.self, from: data) }
        catch { throw LibraryPackageError.notAPackage }
        guard metadata.version <= LibraryPackage.version else {
            throw LibraryPackageError.unsupportedVersion(metadata.version)
        }
        let contentURL = try packageFile(metadata.contentName, in: packageURL)
        guard FileManager.default.fileExists(atPath: contentURL.path) else {
            throw LibraryPackageError.missingFile(metadata.contentName)
        }
        let id = UUID().uuidString
        var created: [URL] = []
        do {
            var body = ""
            var relativePath: String?
            var note: String?
            var kind = ItemKind(rawValue: metadata.kind) ?? .note
            if metadata.contentName.lowercased().hasSuffix(".md") {
                body = try String(contentsOf: contentURL, encoding: .utf8)
            } else {
                let ext = contentURL.pathExtension.filter { $0.isLetter || $0.isNumber }.prefix(16)
                let relative = id + (ext.isEmpty ? "" : "." + ext)
                let destination = files.appendingPathComponent(relative)
                try FileManager.default.copyItem(at: contentURL, to: destination)
                created.append(destination)
                let extraction = TextExtractor.extract(destination, temporaryDirectory: root)
                body = extraction.text
                note = extraction.note
                kind = extraction.kind
                relativePath = relative
            }
            var attachments: [(reference: String, path: String)] = []
            for attachment in metadata.attachments {
                let source = try packageFile(attachment.file, in: packageURL)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let path = "Attachments/" + source.lastPathComponent
                let destination = try images.managedURL(path)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: source, to: destination)
                    created.append(destination)
                }
                attachments.append((attachment.reference, path))
            }
            let fingerprint = try FileFingerprint.sha256(of: contentURL)
            let bytes = (try? contentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let createdStamp = String(metadata.createdAt.timeIntervalSince1970)
            let updatedStamp = String(metadata.updatedAt.timeIntervalSince1970)
            try database.transaction {
                try database.execute("""
                    INSERT INTO items (id,title,kind,relative_path,body,extraction_note,byte_count,created_at,updated_at,image_base_path,fingerprint,ocr_version)
                    VALUES (?,?,?,?,?,?,?,?,?,NULL,?,'0')
                    """, [id, metadata.title, kind.rawValue, relativePath, body, note,
                          String(bytes), createdStamp, updatedStamp, fingerprint])
                for attachment in attachments {
                    try database.execute("INSERT INTO markdown_images (item_id,reference,relative_path,failure) VALUES (?,?,?,NULL)",
                                         [id, attachment.reference, attachment.path])
                }
                for name in metadata.tags {
                    guard let tag = try tagID(named: name, creating: true) else { continue }
                    try database.execute("INSERT OR IGNORE INTO item_tags (item_id,tag_id) VALUES (?,?)", [id, tag])
                }
                if let path = metadata.originalPath {
                    try database.execute("INSERT INTO item_sources (item_id,path) VALUES (?,?)", [id, path])
                }
                try record("从资料包导入了「\(metadata.title)」")
            }
            return try loadItem(id)
        } catch {
            for file in created { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }

    /// Resolves a name inside the package and refuses anything that climbs out.
    private func packageFile(_ name: String, in packageURL: URL) throws -> URL {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\0") else {
            throw LibraryPackageError.pathEscapesPackage(name)
        }
        let url = packageURL.appendingPathComponent(name).standardizedFileURL
        let root = packageURL.standardizedFileURL.path
        guard url.path.hasPrefix(root + "/") else { throw LibraryPackageError.pathEscapesPackage(name) }
        return url
    }

    private func loadItem(_ id: String) throws -> LibraryItem {
        let imageRows = Dictionary(grouping: try database.rows("SELECT * FROM markdown_images WHERE item_id = ? ORDER BY reference", [id]), by: { $0["item_id"]! })
        let sourceRows = Dictionary(grouping: try database.rows("SELECT * FROM item_sources WHERE item_id = ? ORDER BY path", [id]), by: { $0["item_id"]! })
        let tagRows = Dictionary(grouping: try database.rows("""
            SELECT item_tags.item_id AS item_id, tags.name AS name FROM item_tags
            JOIN tags ON tags.id = item_tags.tag_id WHERE item_tags.item_id = ?
            """, [id]), by: { $0["item_id"]! })
        guard let row = try database.rows("SELECT * FROM items WHERE id = ?", [id]).first else {
            throw LibraryPackageError.missingItem
        }
        return try item(from: row, imageRows: imageRows, sourceRows: sourceRows, tagRows: tagRows)
    }

    /// Gives items imported before fingerprints existed one, so they take part in
    /// duplicate detection too. Runs a bounded batch so launch is never held up.
    @discardableResult
    public func backfillFingerprints(limit: Int = 40) throws -> Int {
        let rows = try database.rows("SELECT id, relative_path FROM items WHERE fingerprint IS NULL AND relative_path IS NOT NULL AND deleted_at IS NULL LIMIT ?", [String(limit)])
        var updated = 0
        for row in rows {
            guard let id = row["id"], let relativePath = row["relative_path"] else { continue }
            let copy = files.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: copy.path),
                  let fingerprint = try? FileFingerprint.sha256(of: copy) else { continue }
            try database.execute("UPDATE items SET fingerprint = ? WHERE id = ?", [fingerprint, id])
            updated += 1
        }
        return updated
    }

    /// Reads text out of pictures and scanned PDFs that were imported before the
    /// recognizer existed. One bounded batch per call so launch stays quick; the
    /// caller repeats until it returns zero.
    @discardableResult
    public func backfillOCR(limit: Int = 20) throws -> Int {
        let rows = try database.rows("""
            SELECT id, relative_path FROM items
            WHERE ocr_version = 0 AND relative_path IS NOT NULL AND deleted_at IS NULL
              AND (kind = ? OR lower(relative_path) LIKE '%.pdf')
            ORDER BY created_at, id LIMIT ?
            """, [ItemKind.image.rawValue, String(limit)])
        var processed = 0
        for row in rows {
            guard let id = row["id"], let relativePath = row["relative_path"] else { continue }
            let copy = files.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: copy.path) else {
                // The file is gone; nothing to read, and retrying forever would
                // keep the batch busy with the same row.
                try database.execute("UPDATE items SET ocr_version = 1 WHERE id = ?", [id])
                continue
            }
            let extraction = TextExtractor.extract(copy, temporaryDirectory: root)
            try database.execute("UPDATE items SET body = ?, extraction_note = ?, ocr_version = 1 WHERE id = ?",
                                 [extraction.text, extraction.note, id])
            processed += 1
        }
        return processed
    }

    /// How many items are still waiting for the recognizer.
    public func ocrPendingCount() throws -> Int {
        let rows = try database.rows("""
            SELECT count(*) AS total FROM items
            WHERE ocr_version = 0 AND relative_path IS NOT NULL AND deleted_at IS NULL
              AND (kind = ? OR lower(relative_path) LIKE '%.pdf')
            """, [ItemKind.image.rawValue])
        return Int(rows.first?["total"] ?? "") ?? 0
    }

    private func items(matchingFingerprint fingerprint: String) throws -> [LibraryItem] {
        let rows = try database.rows("SELECT id, title, kind, relative_path, byte_count, created_at, updated_at FROM items WHERE fingerprint = ? AND deleted_at IS NULL ORDER BY created_at, id", [fingerprint])
        return rows.compactMap { row in
            guard let id = row["id"], let title = row["title"], let kind = ItemKind(rawValue: row["kind"] ?? "") else { return nil }
            return LibraryItem(id: id, title: title, kind: kind, relativePath: row["relative_path"],
                               text: "", extractionNote: nil, byteCount: Int64(row["byte_count"] ?? "") ?? 0,
                               createdAt: Date(timeIntervalSince1970: Double(row["created_at"] ?? "") ?? 0),
                               updatedAt: Date(timeIntervalSince1970: Double(row["updated_at"] ?? "") ?? 0),
                               collectionID: nil, favorite: false)
        }
    }

    // MARK: 标签

    /// Replaces the tags of every listed item in one transaction. Names are
    /// trimmed and de-duplicated; missing tags are created, and an empty list
    /// clears the item's tags. Items themselves are never touched.
    @discardableResult
    public func setTags(_ names: [String], for ids: [String]) throws -> Int {
        let cleaned = Self.clean(names)
        guard !ids.isEmpty else { return 0 }
        try database.transaction {
            for id in ids {
                try database.execute("DELETE FROM item_tags WHERE item_id = ?", [id])
                for name in cleaned {
                    guard let tagID = try tagID(named: name, creating: true) else { continue }
                    try database.execute("INSERT OR IGNORE INTO item_tags (item_id, tag_id) VALUES (?, ?)", [id, tagID])
                }
            }
            try record(cleaned.isEmpty ? "清空了 \(ids.count) 项资料的标签" : "为 \(ids.count) 项资料设置了标签 " + cleaned.map { "#\($0)" }.joined(separator: " "))
        }
        return ids.count
    }

    /// Adds tags to items without disturbing the ones they already have.
    @discardableResult
    public func addTags(_ names: [String], to ids: [String]) throws -> Int {
        let cleaned = Self.clean(names)
        guard !ids.isEmpty, !cleaned.isEmpty else { return 0 }
        try database.transaction {
            for id in ids {
                for name in cleaned {
                    guard let tagID = try tagID(named: name, creating: true) else { continue }
                    try database.execute("INSERT OR IGNORE INTO item_tags (item_id, tag_id) VALUES (?, ?)", [id, tagID])
                }
            }
            try record("为 \(ids.count) 项资料加了标签 " + cleaned.map { "#\($0)" }.joined(separator: " "))
        }
        return ids.count
    }

    /// Removes tags from items, leaving the tags (and everything else) in place.
    @discardableResult
    public func removeTags(_ names: [String], from ids: [String]) throws -> Int {
        let cleaned = Self.clean(names)
        guard !ids.isEmpty, !cleaned.isEmpty else { return 0 }
        try database.transaction {
            for id in ids {
                for name in cleaned {
                    guard let tagID = try tagID(named: name, creating: false) else { continue }
                    try database.execute("DELETE FROM item_tags WHERE item_id = ? AND tag_id = ?", [id, tagID])
                }
            }
            try record("从 \(ids.count) 项资料移除了标签 " + cleaned.map { "#\($0)" }.joined(separator: " "))
        }
        return ids.count
    }

    /// Deletes the tag and its links. The items stay exactly as they were.
    public func deleteTag(id: String) throws {
        let name = try database.rows("SELECT name FROM tags WHERE id = ?", [id]).first?["name"] ?? "标签"
        try database.transaction {
            try database.execute("DELETE FROM tags WHERE id = ?", [id])
            try record("删除了标签「\(name)」")
        }
    }

    public func renameTag(id: String, to name: String) throws {
        guard let cleaned = Self.clean([name]).first else { throw LibraryError.message("标签名不能为空") }
        do {
            try database.execute("UPDATE tags SET name = ? WHERE id = ?", [cleaned, id])
            try record("重命名了一个标签为「\(cleaned)」")
        } catch {
            throw LibraryError.message("已经有叫「\(cleaned)」的标签了")
        }
    }

    /// Tag names are single words: the editor splits on spaces and commas, and
    /// `tag:` search has to stay unambiguous.
    private static func clean(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
                .split(whereSeparator: \.isWhitespace).joined()
            guard !trimmed.isEmpty, trimmed.count <= 32, !trimmed.hasPrefix("tag:") else { continue }
            if seen.insert(trimmed.lowercased()).inserted { result.append(trimmed) }
        }
        return result
    }

    private func tagID(named name: String, creating: Bool) throws -> String? {
        if let existing = try database.rows("SELECT id FROM tags WHERE name = ?", [name]).first?["id"] { return existing }
        guard creating else { return nil }
        let id = UUID().uuidString
        try database.execute("INSERT INTO tags (id, name) VALUES (?, ?)", [id, name])
        return id
    }

    public func saveNote(id: String? = nil, title: String, body: String, kind: ItemKind, collectionID: String? = nil) throws -> String {
        guard kind == .note || kind == .thought else { throw LibraryError.message("只有笔记和随笔可以编辑") }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LibraryError.message("请输入标题") }
        guard title.count <= 300, body.count <= TextExtractor.maximumCharacters else { throw LibraryError.message("标题最多 300 字，正文最多 200 万字") }
        let itemID = id ?? UUID().uuidString
        let now = String(Date().timeIntervalSince1970)
        let existing = try database.rows("SELECT kind, image_base_path FROM items WHERE id = ?", [itemID]).first
        if id != nil, existing?["kind"] != kind.rawValue { throw LibraryError.message("笔记已不存在或类型不匹配") }
        let prepared = try images.prepare(text: body, basePath: existing?["image_base_path"], existing: imageEntries(id: itemID), refresh: false)
        try publishImages(prepared, id: itemID) {
            if let id {
                try database.execute("UPDATE items SET title = ?, body = ?, updated_at = ?, byte_count = ? WHERE id = ?", [title, body, now, String(body.utf8.count), id])
            } else {
                try database.execute("INSERT INTO items (id,title,kind,body,byte_count,created_at,updated_at,collection_id) VALUES (?,?,?,?,?,?,?,?)", [itemID, title, kind.rawValue, body, String(body.utf8.count), now, now, collectionID])
            }
            try record("\(id == nil ? "新建" : "更新")了\(kind.label)「\(title)」")
        }
        return itemID
    }

    public func createCollection(name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw LibraryError.message("目录名需为 1 至 80 个字符") }
        let id = UUID().uuidString
        try database.transaction {
            guard try database.rows("SELECT id FROM collections WHERE name = ? COLLATE NOCASE", [name]).isEmpty else { throw LibraryError.message("已有同名目录") }
            try database.execute("INSERT INTO collections (id,name) VALUES (?,?)", [id, name])
            try record("新建目录「\(name)」")
        }
        return id
    }

    public func setFavorite(id: String, value: Bool) throws {
        guard try !database.rows("SELECT id FROM items WHERE id = ?", [id]).isEmpty else { throw LibraryError.message("资料不存在") }
        try setFavorite(ids: [id], value: value)
    }

    public func setFavorite(ids: [String], value: Bool) throws {
        let ids = Array(Set(ids)).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        try database.transaction {
            for chunk in Self.chunks(ids) {
                let placeholders = Self.placeholders(chunk.count)
                try database.execute("UPDATE items SET favorite = ? WHERE id IN (\(placeholders))",
                                     [value ? "1" : "0"] + Self.optional(chunk))
            }
        }
    }

    public func organize(id: String, collectionID: String?) throws {
        try organize(ids: [id], collectionID: collectionID)
    }

    public func organize(ids: [String], collectionID: String?) throws {
        let ids = Array(Set(ids)).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        try database.transaction {
            var target = "待整理"
            if let collectionID {
                guard let collection = try database.rows("SELECT name FROM collections WHERE id = ?", [collectionID]).first else { throw LibraryError.message("目录不存在") }
                target = collection["name"]!
            }
            var titles: [String] = []
            for chunk in Self.chunks(ids) {
                let placeholders = Self.placeholders(chunk.count)
                titles += try database.rows("SELECT title FROM items WHERE id IN (\(placeholders))",
                                            Self.optional(chunk)).compactMap { $0["title"] }
                try database.execute("UPDATE items SET collection_id = ? WHERE id IN (\(placeholders))",
                                     [collectionID] + Self.optional(chunk))
            }
            guard titles.count == ids.count else { throw LibraryError.message("部分资料已不存在，请刷新后重试") }
            if titles.count == 1 {
                try record("将「\(titles[0])」归入「\(target)」")
            } else {
                try record("将 \(titles.count) 项资料归入「\(target)」")
            }
        }
    }

    /// Moves items to the trash. The row, its managed copy, and its archived
    /// images stay where they are, so restoring is a single column update.
    @discardableResult
    public func moveToTrash(ids: [String]) throws -> Int {
        let ids = Array(Set(ids)).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return 0 }
        var titles: [String] = []
        try database.transaction {
            for chunk in Self.chunks(ids) {
                let placeholders = Self.placeholders(chunk.count)
                titles += try database.rows("SELECT title FROM items WHERE id IN (\(placeholders)) AND deleted_at IS NULL",
                                            Self.optional(chunk)).compactMap { $0["title"] }
                try database.execute("UPDATE items SET deleted_at = ? WHERE id IN (\(placeholders)) AND deleted_at IS NULL",
                                     [String(Date().timeIntervalSince1970)] + Self.optional(chunk))
            }
            if titles.count == 1 {
                try record("将「\(titles[0])」移到回收站")
            } else if !titles.isEmpty {
                try record("将 \(titles.count) 项资料移到回收站")
            }
        }
        return titles.count
    }

    /// Puts trashed items back in place. Nothing was moved, so the original
    /// collection, favorite state, copies, and archived images are already intact.
    @discardableResult
    public func restoreFromTrash(ids: [String]) throws -> Int {
        let ids = Array(Set(ids)).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return 0 }
        var titles: [String] = []
        try database.transaction {
            for chunk in Self.chunks(ids) {
                let placeholders = Self.placeholders(chunk.count)
                titles += try database.rows("SELECT title FROM items WHERE id IN (\(placeholders)) AND deleted_at IS NOT NULL",
                                            Self.optional(chunk)).compactMap { $0["title"] }
                try database.execute("UPDATE items SET deleted_at = NULL WHERE id IN (\(placeholders))", Self.optional(chunk))
            }
            if titles.count == 1 {
                try record("恢复了「\(titles[0])」")
            } else if !titles.isEmpty {
                try record("恢复了 \(titles.count) 项资料")
            }
        }
        return titles.count
    }

    /// Removes database rows, managed file copies, and archived images that no
    /// remaining item references. Original files outside the library are untouched.
    /// This is the only path that deletes copies, so it stays off the delete button.
    public func permanentlyDelete(ids: [String]) throws -> LibraryDeletionReport {
        let ids = Array(Set(ids)).filter { !$0.isEmpty }
        var report = LibraryDeletionReport()
        guard !ids.isEmpty else { return report }

        var deleted: [DeletedLibraryItem] = []
        var attachments: Set<String> = []
        try database.transaction {
            for chunk in Self.chunks(ids) {
                let placeholders = Self.placeholders(chunk.count)
                let rows = try database.rows("SELECT title, relative_path FROM items WHERE id IN (\(placeholders))",
                                             Self.optional(chunk))
                deleted += rows.map {
                    DeletedLibraryItem(title: $0["title"] ?? "未命名资料", relativePath: $0["relative_path"])
                }
                let images = try database.rows(
                    "SELECT relative_path FROM markdown_images WHERE item_id IN (\(placeholders)) AND relative_path IS NOT NULL",
                    Self.optional(chunk))
                attachments.formUnion(images.compactMap { $0["relative_path"] })
                try database.execute("DELETE FROM items WHERE id IN (\(placeholders))", Self.optional(chunk))
            }
            if deleted.count == 1 {
                try record("删除了「\(deleted[0].title)」")
            } else if !deleted.isEmpty {
                try record("删除了 \(deleted.count) 项资料")
            }
        }

        report.deleted = deleted.count
        for item in deleted {
            guard let relative = item.relativePath else { continue }
            do {
                let url = try managedFileURL(relative: relative)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                report.warnings.append("「\(item.title)」：\(error.localizedDescription)")
            }
        }
        for path in attachments.sorted() {
            do {
                let stillReferenced = try !database.rows(
                    "SELECT 1 FROM markdown_images WHERE relative_path = ? LIMIT 1", [path]).isEmpty
                guard !stillReferenced else { continue }
                let url = try images.managedURL(path)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                report.warnings.append("配图 \(path)：\(error.localizedDescription)")
            }
        }
        return report
    }

    public func emptyTrash() throws -> LibraryDeletionReport {
        let ids = try database.rows("SELECT id FROM items WHERE deleted_at IS NOT NULL").compactMap { $0["id"] }
        return try permanentlyDelete(ids: ids)
    }

    /// Called once per launch: trashed items older than the retention window are
    /// physically removed with their copies.
    @discardableResult
    public func purgeExpiredTrash(olderThan interval: TimeInterval = LibraryRetention.trash) throws -> LibraryDeletionReport {
        let cutoff = String(Date().timeIntervalSince1970 - interval)
        let ids = try database.rows("SELECT id FROM items WHERE deleted_at IS NOT NULL AND deleted_at < ?", [cutoff])
            .compactMap { $0["id"] }
        guard !ids.isEmpty else { return LibraryDeletionReport() }
        return try permanentlyDelete(ids: ids)
    }

    @discardableResult
    public func setImageBaseDirectory(id: String, directory: URL) throws -> MarkdownImageCopyReport {
        guard directory.isFileURL, [nil, "", "localhost"].contains(directory.host?.lowercased()),
              try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw LibraryError.message("请选择本机图片目录")
        }
        guard let row = try database.rows("SELECT * FROM items WHERE id = ?", [id]).first else {
            throw LibraryError.message("资料不存在")
        }
        let ext = URL(fileURLWithPath: row["relative_path"] ?? "").pathExtension.lowercased()
        guard ["note", "thought"].contains(row["kind"] ?? "") || ["md", "markdown"].contains(ext) else {
            throw LibraryError.message("仅 Markdown 文件、笔记和随笔支持图片目录")
        }
        let access = directory.startAccessingSecurityScopedResource()
        defer { if access { directory.stopAccessingSecurityScopedResource() } }
        let base = directory.standardizedFileURL.path
        let prepared = try images.prepare(text: markdownText(row), basePath: base, existing: imageEntries(id: id), refresh: true)
        try publishImages(prepared, id: id) {
            try database.execute("UPDATE items SET image_base_path = ? WHERE id = ?", [base, id])
        }
        return prepared.report
    }

    /// Idempotently archive references in an existing Markdown file or editable note.
    @discardableResult
    public func copyMarkdownImages(id: String) throws -> MarkdownImageCopyReport {
        guard let row = try database.rows("SELECT * FROM items WHERE id = ?", [id]).first else { throw LibraryError.message("资料不存在") }
        let prepared = try images.prepare(text: markdownText(row), basePath: row["image_base_path"], existing: imageEntries(id: id), refresh: false)
        try publishImages(prepared, id: id) {}
        return prepared.report
    }

    private func markdownText(_ row: [String: String]) throws -> String {
        if ["note", "thought"].contains(row["kind"] ?? "") { return row["body"] ?? "" }
        guard let path = row["relative_path"], ["md", "markdown"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
              !path.contains("/"), path != ".", path != ".." else { throw LibraryError.message("仅 Markdown 文件、笔记和随笔支持配图") }
        let file = files.appendingPathComponent(path)
        guard file.resolvingSymlinksInPath().deletingLastPathComponent() == files.resolvingSymlinksInPath() else { throw LibraryError.message("文件路径超出资料库") }
        return try images.fullMarkdown(at: file)
    }

    private func imageEntries(id: String) throws -> [MarkdownAttachmentEntry] {
        try database.rows("SELECT * FROM markdown_images WHERE item_id = ?", [id]).map {
            MarkdownAttachmentEntry(reference: $0["reference"]!, relativePath: $0["relative_path"], failure: $0["failure"])
        }
    }

    private func publishImages(_ prepared: PreparedMarkdownImages, id: String, update: () throws -> Void) throws {
        do {
            try database.transaction {
                try update()
                try database.execute("DELETE FROM markdown_images WHERE item_id = ?", [id])
                for entry in prepared.entries {
                    try database.execute("INSERT INTO markdown_images (item_id,reference,relative_path,failure) VALUES (?,?,?,?)", [id, entry.reference, entry.relativePath, entry.failure])
                }
            }
        } catch {
            let original = error
            var cleanup: [String] = []
            for file in prepared.created {
                do {
                    let path = "Attachments/" + file.lastPathComponent
                    if try database.rows("SELECT item_id FROM markdown_images WHERE relative_path = ? LIMIT 1", [path]).isEmpty {
                        try FileManager.default.removeItem(at: file)
                    }
                } catch { cleanup.append(error.localizedDescription) }
            }
            if !cleanup.isEmpty { throw LibraryError.message("\(original.localizedDescription)；未提交配图清理失败：\(cleanup.joined(separator: "；"))") }
            throw original
        }
    }

    /// Restore pre-migration provenance only after matching the full file contents.
    /// Additional paths can represent identical files merged by an earlier import.
    public func restoreSourceLocations(id: String, urls: [URL]) throws {
        guard let row = try database.rows("SELECT relative_path FROM items WHERE id = ?", [id]).first, !urls.isEmpty else {
            throw LibraryError.message("资料不存在或没有来源地址")
        }
        let managed = try fileURL(relative: row["relative_path"])
        let expected = try Self.fileDigest(managed)
        var paths: [String] = []
        for source in urls {
            guard source.isFileURL, [nil, "", "localhost"].contains(source.host?.lowercased()),
                  try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw LibraryError.message("来源必须为本机普通文件")
            }
            guard try Self.fileDigest(source) == expected else { throw LibraryError.message("来源内容与资料库副本不一致，未建立链接") }
            paths.append(source.standardizedFileURL.path)
        }
        try database.transaction {
            for path in paths {
                try database.execute("INSERT OR IGNORE INTO item_sources (item_id,path) VALUES (?,?)", [id, path])
            }
        }
    }

    private static func fileDigest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize()
    }

    public nonisolated func fileURL(for item: LibraryItem) throws -> URL {
        try fileURL(relative: item.relativePath)
    }

    private nonisolated func fileURL(relative: String?) throws -> URL {
        let url = try managedFileURL(relative: relative)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryError.message("资料库中的文件已不在原位置，请从备份恢复。") }
        return url
    }

    private nonisolated func managedFileURL(relative: String?) throws -> URL {
        guard let relative, !relative.isEmpty, !relative.contains("/"), relative != ".", relative != ".." else {
            throw LibraryError.message("文件路径无效")
        }
        let folder = root.appendingPathComponent("Files", isDirectory: true)
        let url = folder.appendingPathComponent(relative)
        let parent = folder.resolvingSymlinksInPath().standardizedFileURL
        guard url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL == parent else {
            throw LibraryError.message("文件路径超出资料库")
        }
        return url
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private static func optional(_ ids: [String]) -> [String?] {
        ids.map { Optional($0) }
    }

    private static func chunks(_ ids: [String], size: Int = 400) -> [[String]] {
        guard size > 0 else { return [ids] }
        return stride(from: 0, to: ids.count, by: size).map {
            Array(ids[$0..<min($0 + size, ids.count)])
        }
    }

    /// Search metadata plus FTS candidates; the full body is only read for rows
    /// that can match, then discarded before results leave the actor.
    public func search(query: String, filter: LibrarySearchFilter = LibrarySearchFilter()) throws -> LibrarySearchResults {
        // `tag:名称` narrows the same way the sidebar does, so clicking a tag and
        // typing the prefix return the same rows.
        let split = LibrarySearch.split(query)
        let tagName = filter.tagName ?? split.tag
        let words = split.terms
        let terms = words.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty || tagName != nil else { return LibrarySearchResults(query: query) }

        var scopeClauses: [String] = ["deleted_at IS NULL"]
        var scopeValues: [String?] = []
        if let tagName {
            scopeClauses.append("id IN (SELECT item_tags.item_id FROM item_tags JOIN tags ON tags.id = item_tags.tag_id WHERE tags.name = ?)")
            scopeValues.append(tagName)
        }
        if let kind = filter.kind {
            scopeClauses.append("kind = ?")
            scopeValues.append(kind.rawValue)
        }
        if filter.favoritesOnly { scopeClauses.append("favorite = 1") }
        if filter.inboxOnly { scopeClauses.append("collection_id IS NULL") }
        if let collection = filter.collectionID {
            scopeClauses.append("collection_id = ?")
            scopeValues.append(collection)
        }
        let scopeClause = scopeClauses.isEmpty ? "1=1" : scopeClauses.joined(separator: " AND ")

        var searchClauses: [String] = []
        var searchValues: [String?] = []
        for term in terms {
            if database.supportsFTS, term.count >= 3 {
                let expression = Self.trigrams(term).map(Self.ftsQuoted).joined(separator: " AND ")
                if !expression.isEmpty {
                    searchClauses.append("rowid IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?)")
                    searchValues.append(expression)
                    continue
                }
            }
            let pattern = Self.likePattern(term)
            searchClauses.append("(title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\')")
            searchValues.append(pattern)
            searchValues.append(pattern)
        }
        let searchClause = searchClauses.isEmpty ? "1=1" : searchClauses.joined(separator: " AND ")

        let source = "SELECT rowid AS rowid, * FROM items WHERE \(scopeClause)"
        let sql: String
        if let limit = filter.recentLimit {
            sql = "SELECT * FROM (\(source) ORDER BY created_at DESC LIMIT \(max(1, limit))) WHERE \(searchClause) ORDER BY updated_at DESC, id"
        } else {
            sql = "SELECT * FROM (\(source) AND \(searchClause)) ORDER BY updated_at DESC, id"
        }
        let started = Date()
        var width = 1
        let rows: [[String: String]]
        // Short terms cannot use the trigram index, so they scan every body. That
        // scan is split across read-only connections once the library is big
        // enough to make the split worth it (see script/search-benchmark.py).
        if filter.recentLimit == nil,
           (terms.contains { $0.count < 3 } || !database.supportsFTS),
           terms.count <= Self.scanTermLimit,
           let slices = try scanSlices() {
            rows = try Self.scan(root: root, scope: scopeClause, search: searchClause,
                                 scopeValues: scopeValues, searchValues: searchValues, slices: slices)
            width = slices.count
        } else {
            rows = try database.rows(sql, scopeValues + searchValues)
        }
        Self.logSlowSearch(started, terms: terms.count, width: width)
        var candidates: [LibraryItem] = []
        candidates.reserveCapacity(rows.count)
        for row in rows {
            guard let id = row["id"], let title = row["title"], let rawKind = row["kind"], let kind = ItemKind(rawValue: rawKind),
                  let body = row["body"], let created = Double(row["created_at"] ?? ""), let updated = Double(row["updated_at"] ?? ""),
                  let size = Int64(row["byte_count"] ?? "") else {
                throw LibraryError.message("资料库记录格式损坏，请保留数据目录并恢复备份。")
            }
            candidates.append(LibraryItem(
                id: id, title: title, kind: kind, relativePath: row["relative_path"], text: body,
                extractionNote: row["extraction_note"], byteCount: size,
                createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: updated),
                collectionID: row["collection_id"], favorite: row["favorite"] == "1",
                imageBasePath: row["image_base_path"], preview: String(body.prefix(240)), textLoaded: true
            ))
        }
        guard !terms.isEmpty else {
            // A tag on its own lists the tag, same order as an unfiltered list.
            let list = candidates.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
            return LibrarySearchResults(query: query, items: list)
        }
        let matched = try LibrarySearch.search(candidates, query: words)
        // A title hit outranks a hit buried in the body; ties fall back to the old
        // updated_at order, so two runs of the same query agree on the list.
        let ranked = matched.items
            .map { (item: $0, relevance: LibrarySearch.relevance(of: $0, query: words)) }
            .sorted { lhs, rhs in
                if lhs.relevance != rhs.relevance { return lhs.relevance < rhs.relevance }
                if lhs.item.updatedAt != rhs.item.updatedAt { return lhs.item.updatedAt > rhs.item.updatedAt }
                return lhs.item.id < rhs.item.id
            }
            .map(\.item)
        let stripped = ranked.map { item -> LibraryItem in
            var item = item
            item.text = ""
            item.textLoaded = false
            return item
        }
        return LibrarySearchResults(query: query, items: stripped, presentations: matched.presentations)
    }

    public func body(for id: String) throws -> String? {
        try database.rows("SELECT body FROM items WHERE id = ?", [id]).first?["body"]
    }

    /// A bounded rowid range of one parallel scan.
    private struct ScanSlice: Sendable {
        let low: Int64
        let high: Int64
    }

    /// Above this size a short-query scan is worth splitting across cores.
    static let defaultScanMinimumBytes: Int64 = 32 * 1024 * 1024
    /// Scanned pages the recognizer will read in one PDF, surfaced in Settings.
    public static let maximumScannedPages = TextExtractor.maximumOCRedPages
    private static let scanWidth = 4
    /// Every term is ANDed into one scan, so this only guards against pathological
    /// queries; it is not a per-term cost.
    private static let scanTermLimit = 6
    private static let searchLog = Logger(subsystem: "com.longyinpro.personal-library", category: "search")

    private func scanSlices() throws -> [ScanSlice]? {
        guard try database.byteSize() >= scanMinimumBytes else { return nil }
        let bounds = try database.rows("SELECT min(rowid) AS low, max(rowid) AS high FROM items").first
        guard let low = Int64(bounds?["low"] ?? ""), let high = Int64(bounds?["high"] ?? ""), high >= low else { return nil }
        let step = (high - low) / Int64(Self.scanWidth) + 1
        return (0..<Self.scanWidth).map { index in
            let start = low + Int64(index) * step
            return ScanSlice(low: start, high: min(high, start + step - 1))
        }
    }

    /// Runs the same WHERE clause over disjoint rowid ranges on separate read-only
    /// connections, then restores the single-query ordering.
    private nonisolated static func scan(root: URL, scope: String, search: String,
                                         scopeValues: [String?], searchValues: [String?],
                                         slices: [ScanSlice]) throws -> [[String: String]] {
        let sql = "SELECT rowid AS rowid, * FROM items WHERE \(scope) AND \(search) AND rowid BETWEEN ? AND ?"
        let lock = NSLock()
        var pieces = [[[String: String]]](repeating: [], count: slices.count)
        var failure: Error?
        DispatchQueue.concurrentPerform(iterations: slices.count) { index in
            do {
                let connection = try Database(readOnly: root.appendingPathComponent("library.sqlite"))
                let rows = try connection.rows(sql, scopeValues + searchValues + [String(slices[index].low), String(slices[index].high)])
                lock.lock(); pieces[index] = rows; lock.unlock()
            } catch {
                lock.lock(); if failure == nil { failure = error }; lock.unlock()
            }
        }
        if let failure { throw failure }
        var rows = pieces.flatMap { $0 }
        rows.sort { left, right in
            let a = Double(left["updated_at"] ?? "") ?? 0
            let b = Double(right["updated_at"] ?? "") ?? 0
            if a != b { return a > b }
            return (left["id"] ?? "") < (right["id"] ?? "")
        }
        return rows
    }

    /// A short query that takes long is worth knowing about; terms stay out of the
    /// log because they are user content.
    private static func logSlowSearch(_ started: Date, terms: Int, width: Int) {
        let milliseconds = Date().timeIntervalSince(started) * 1000
        guard milliseconds >= 150 else { return }
        searchLog.notice("短词扫描 \(terms, privacy: .public) 个词用时 \(Int(milliseconds), privacy: .public) ms，\(width, privacy: .public) 路")
    }

    private static func trigrams(_ term: String) -> [String] {
        let characters = Array(term)
        guard characters.count >= 3 else { return [] }
        return (0...(characters.count - 3)).map { String(characters[$0..<($0 + 3)]) }
    }

    private static func ftsQuoted(_ trigram: String) -> String {
        "\"" + trigram.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func likePattern(_ term: String) -> String {
        var escaped = term.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "%", with: "\\%")
        escaped = escaped.replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    private func record(_ message: String) throws {
        try database.execute("INSERT INTO activities (id,message,date) VALUES (?,?,?)", [UUID().uuidString, message, String(Date().timeIntervalSince1970)])
    }

    /// Writes a consistent copy of the database into `Backups/` and rotates old
    /// copies. Notes are in SQLite; the imported file copies under `Files/` are
    /// not part of this snapshot.
    @discardableResult
    public func createBackup(at date: Date = Date()) throws -> LibraryBackup {
        let directory = try LibraryBackupStore.makeDirectory(in: root)
        let url = directory.appendingPathComponent(LibraryBackupStore.fileName(for: date))
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try database.backup(to: url)
        try LibraryBackupStore.prune(in: root)
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        return LibraryBackup(url: url, date: date, byteCount: size)
    }

    public func backups() throws -> [LibraryBackup] {
        try LibraryBackupStore.backups(in: root)
    }
}

private struct DeletedLibraryItem {
    let title: String
    let relativePath: String?
}
