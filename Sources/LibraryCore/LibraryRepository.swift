import CryptoKit
import Foundation

public actor LibraryRepository {
    public nonisolated let root: URL
    private let database: Database
    private let files: URL
    private var images: MarkdownAttachments { MarkdownAttachments(root: root) }

    public init(root: URL) throws {
        self.root = root
        self.files = root.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Attachments", isDirectory: true), withIntermediateDirectories: true)
        self.database = try Database(url: root.appendingPathComponent("library.sqlite"))
    }

    public func snapshot() throws -> LibrarySnapshot {
        var snapshot = LibrarySnapshot()
        let imageRows = Dictionary(grouping: try database.rows("SELECT * FROM markdown_images ORDER BY reference"), by: { $0["item_id"]! })
        let sourceRows = Dictionary(grouping: try database.rows("SELECT * FROM item_sources ORDER BY path"), by: { $0["item_id"]! })
        let columns = """
            id, title, kind, relative_path, substr(body, 1, 240) AS preview,
                   extraction_note, byte_count, created_at, updated_at, collection_id,
                   favorite, image_base_path, deleted_at
            """
        snapshot.items = try database.rows("SELECT \(columns) FROM items WHERE deleted_at IS NULL ORDER BY updated_at DESC, id")
            .map { try item(from: $0, imageRows: imageRows, sourceRows: sourceRows) }
        snapshot.trashed = try database.rows("SELECT \(columns) FROM items WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC, id")
            .map { try item(from: $0, imageRows: imageRows, sourceRows: sourceRows) }
        snapshot.collections = try database.rows("SELECT * FROM collections ORDER BY name COLLATE NOCASE").map {
            LibraryCollection(id: $0["id"]!, name: $0["name"]!)
        }
        snapshot.activities = try database.rows("SELECT * FROM activities ORDER BY date DESC LIMIT 200").map {
            LibraryActivity(id: $0["id"]!, message: $0["message"]!, date: Date(timeIntervalSince1970: Double($0["date"]!)!))
        }
        return snapshot
    }

    private func item(from row: [String: String], imageRows: [String: [[String: String]]],
                      sourceRows: [String: [[String: String]]]) throws -> LibraryItem {
        guard let id = row["id"], let title = row["title"], let rawKind = row["kind"], let kind = ItemKind(rawValue: rawKind),
              let created = Double(row["created_at"] ?? ""), let updated = Double(row["updated_at"] ?? ""),
              let size = Int64(row["byte_count"] ?? "") else { throw LibraryError.message("资料库记录格式损坏，请保留数据目录并恢复备份。") }
        let attached = try (imageRows[id] ?? []).reduce(into: [String: URL]()) { result, image in
            if let path = image["relative_path"] { result[image["reference"]!] = try images.managedURL(path) }
        }
        let issues = (imageRows[id] ?? []).compactMap { image in image["failure"].map { "\(image["reference"]!)：\($0)" } }
        return LibraryItem(id: id, title: title, kind: kind, relativePath: row["relative_path"], text: "", extractionNote: row["extraction_note"], byteCount: size, createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: updated), collectionID: row["collection_id"], favorite: row["favorite"] == "1", imageBasePath: row["image_base_path"], imageAttachments: attached, imageAttachmentIssues: issues, sourcePaths: (sourceRows[id] ?? []).compactMap { $0["path"] }, preview: row["preview"] ?? "", textLoaded: false, deletedAt: row["deleted_at"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) })
    }

    public func importFiles(_ urls: [URL]) throws -> ImportReport {
        var report = ImportReport()
        for source in urls {
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
                    try database.execute("INSERT INTO items (id,title,kind,relative_path,body,extraction_note,byte_count,created_at,updated_at,image_base_path) VALUES (?,?,?,?,?,?,?,?,?,?)", [id, source.lastPathComponent, extraction.kind.rawValue, relativePath, extraction.text, extraction.note, String(values.fileSize ?? 0), now, now, imageBase])
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

    @discardableResult
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
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return LibrarySearchResults(query: query) }

        var scopeClauses: [String] = ["deleted_at IS NULL"]
        var scopeValues: [String?] = []
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
        let searchClause = searchClauses.joined(separator: " AND ")

        let source = "SELECT rowid AS rowid, * FROM items WHERE \(scopeClause)"
        let sql: String
        if let limit = filter.recentLimit {
            sql = "SELECT * FROM (\(source) ORDER BY created_at DESC LIMIT \(max(1, limit))) WHERE \(searchClause) ORDER BY updated_at DESC, id"
        } else {
            sql = "SELECT * FROM (\(source) AND \(searchClause)) ORDER BY updated_at DESC, id"
        }
        let rows = try database.rows(sql, scopeValues + searchValues)
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
        let matched = try LibrarySearch.search(candidates, query: query)
        let stripped = matched.items.map { item -> LibraryItem in
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
}

private struct DeletedLibraryItem {
    let title: String
    let relativePath: String?
}
