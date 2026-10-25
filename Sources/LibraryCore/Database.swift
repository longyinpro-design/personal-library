import CSQLite
import Foundation

/// Owned exclusively by LibraryRepository's serial actor executor.
final class Database {
    /// Current schema version, written to `PRAGMA user_version`. Backups record
    /// theirs, so this is the one place that knows what a build can read.
    static let schemaVersion = 11

    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// FTS5 is present on every supported macOS, but keep search working if a
    /// future system SQLite is built without it.
    private(set) var supportsFTS = false

    /// A connection that never migrates or writes; used by the parallel scan
    /// that answers one- and two-character searches.
    init(readOnly url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(handle)
            handle = nil
            throw LibraryError.message(message)
        }
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA mmap_size = \(Self.mmapBytes)")
    }

    /// Mapping the file lets the scanning path read pages without a copy.
    private static let mmapBytes = 256 * 1024 * 1024

    /// Total size of the database file in bytes, used to decide whether a short
    /// query is worth splitting across cores.
    func byteSize() throws -> Int64 {
        let pages = Int64(try rows("PRAGMA page_count").first?["page_count"] ?? "0") ?? 0
        let size = Int64(try rows("PRAGMA page_size").first?["page_size"] ?? "0") ?? 0
        return pages * size
    }

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(handle)
            handle = nil
            throw LibraryError.message(message)
        }
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA mmap_size = \(Self.mmapBytes)")
        let version = try rows("PRAGMA user_version").first?["user_version"] ?? "0"
        guard version == "0" || (Int(version) ?? 99) <= Self.schemaVersion else { throw LibraryError.message("资料库版本较新，请使用更新版本的 App 打开。") }
        try transaction {
            try execute("CREATE TABLE IF NOT EXISTS collections (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE)")
            try execute("""
                CREATE TABLE IF NOT EXISTS items (
                    id TEXT PRIMARY KEY, title TEXT NOT NULL, kind TEXT NOT NULL,
                    relative_path TEXT, body TEXT NOT NULL, extraction_note TEXT,
                    byte_count INTEGER NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
                    collection_id TEXT REFERENCES collections(id), favorite INTEGER NOT NULL DEFAULT 0
                )
                """)
            try execute("CREATE TABLE IF NOT EXISTS activities (id TEXT PRIMARY KEY, message TEXT NOT NULL, date REAL NOT NULL)")
            if ["0", "1"].contains(version), try !hasColumn("image_base_path", in: "items") {
                try execute("ALTER TABLE items ADD COLUMN image_base_path TEXT")
            }
            // Version 6 moved deletion from a DELETE statement to a column, so a
            // mis-deletion stays recoverable for 30 days. A half-applied upgrade can
            // leave the column behind, so the check also keeps the migration rerunnable.
            if ["0", "1", "2", "3", "4", "5"].contains(version), try !hasColumn("deleted_at", in: "items") {
                try execute("ALTER TABLE items ADD COLUMN deleted_at REAL")
            }
            try execute("CREATE INDEX IF NOT EXISTS items_deleted ON items(deleted_at)")
            // Version 7 keeps a SHA-256 of the imported file next to the item, so a
            // second import of the same bytes can say so before copying anything.
            if ["0", "1", "2", "3", "4", "5", "6"].contains(version), try !hasColumn("fingerprint", in: "items") {
                try execute("ALTER TABLE items ADD COLUMN fingerprint TEXT")
            }
            try execute("CREATE INDEX IF NOT EXISTS items_fingerprint ON items(fingerprint)")
            // Version 8: tags are many-to-many with items. Deleting an item or a tag
            // removes only the links, never the other side.
            try execute("""
                CREATE TABLE IF NOT EXISTS tags (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL COLLATE NOCASE UNIQUE
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS item_tags (
                    item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                    tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                    PRIMARY KEY (item_id, tag_id)
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS item_tags_tag ON item_tags(tag_id)")
            // Version 9 records that the on-device recognizer already ran, so a
            // picture with no words in it is not read again on every launch.
            if ["0", "1", "2", "3", "4", "5", "6", "7", "8"].contains(version), try !hasColumn("ocr_version", in: "items") {
                try execute("ALTER TABLE items ADD COLUMN ocr_version INTEGER NOT NULL DEFAULT 0")
            }
            // Version 10 remembers where reading stopped. The column holds opaque
            // bytes: the app decides whether that means a Markdown section or a
            // plain-text chunk, so the shape can change without a migration.
            if ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"].contains(version),
               try !hasColumn("reading_position", in: "items") {
                try execute("ALTER TABLE items ADD COLUMN reading_position TEXT")
            }
            // Version 11 nests collections. `name` stays globally unique (the
            // table is not rebuilt), so a child cannot repeat a name used
            // anywhere else; depth is capped by the validation in the
            // repository rather than by the schema.
            if ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10"].contains(version),
               try !hasColumn("parent_id", in: "collections") {
                try execute("ALTER TABLE collections ADD COLUMN parent_id TEXT")
            }
            try execute("CREATE INDEX IF NOT EXISTS collections_parent ON collections(parent_id)")
            try execute("""
                CREATE TABLE IF NOT EXISTS markdown_images (
                    item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                    reference TEXT NOT NULL, relative_path TEXT, failure TEXT,
                    PRIMARY KEY (item_id, reference),
                    CHECK (relative_path IS NOT NULL OR failure IS NOT NULL)
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS item_sources (
                    item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                    path TEXT NOT NULL, PRIMARY KEY (item_id, path)
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS item_sources_path ON item_sources(path)")
            do {
                try execute("""
                    CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
                        title, body,
                        content='items', content_rowid='rowid',
                        tokenize='trigram', detail=none
                    )
                    """)
                try execute("""
                    CREATE TRIGGER IF NOT EXISTS items_fts_insert AFTER INSERT ON items BEGIN
                        INSERT INTO items_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
                    END
                    """)
                try execute("""
                    CREATE TRIGGER IF NOT EXISTS items_fts_delete AFTER DELETE ON items BEGIN
                        INSERT INTO items_fts(items_fts, rowid, title, body)
                        VALUES ('delete', old.rowid, old.title, old.body);
                    END
                    """)
                try execute("""
                    CREATE TRIGGER IF NOT EXISTS items_fts_update AFTER UPDATE OF title, body ON items BEGIN
                        INSERT INTO items_fts(items_fts, rowid, title, body)
                        VALUES ('delete', old.rowid, old.title, old.body);
                        INSERT INTO items_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
                    END
                    """)
                // The trigram schema last changed at version 5. Rebuild once for older
                // libraries; rebuild every launch when the check tracks the schema number.
                if let current = Int(version), current < 5 {
                    try execute("INSERT INTO items_fts(items_fts) VALUES('rebuild')")
                }
                supportsFTS = true
            } catch {
                supportsFTS = false
            }
            try execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    deinit { sqlite3_close(handle) }

    /// An upgrade interrupted between the ALTER and the version bump repeats the
    /// ALTER on the next launch, so each column add is keyed off the table shape.
    private func hasColumn(_ name: String, in table: String) throws -> Bool {
        try rows("PRAGMA table_info(\(table))").contains { $0["name"] == name }
    }

    func execute(_ sql: String, _ values: [String?] = []) throws {
        _ = try rows(sql, values)
    }

    /// Writes a consistent copy of the live database. `VACUUM INTO` goes through
    /// SQLite itself, so the copy includes whatever is still in the WAL.
    func backup(to url: URL) throws {
        try execute("VACUUM INTO ?", [url.path])
    }

    func rows(_ sql: String, _ values: [String?] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let result: Int32
            if let value {
                result = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(value.utf8.count), transient) }
            } else {
                result = sqlite3_bind_null(statement, Int32(index + 1))
            }
            guard result == SQLITE_OK else { throw failure() }
        }
        var result: [[String: String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure() }
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                if let value = sqlite3_column_text(statement, i) {
                    let buffer = UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, i)))
                    row[String(cString: sqlite3_column_name(statement, i))] = String(decoding: buffer, as: UTF8.self)
                }
            }
            result.append(row)
        }
        return result
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            let original = error
            do { try execute("ROLLBACK") }
            catch { throw LibraryError.message("保存失败且回滚失败：\(original.localizedDescription)；\(error.localizedDescription)") }
            throw original
        }
    }

    private func failure() -> LibraryError {
        .message("本地数据库操作失败：\(String(cString: sqlite3_errmsg(handle)))")
    }
}
