import Foundation
import Testing
@testable import LibraryCore

struct MarkdownImageDirectoryTests {
    /// Columns every version has kept, so the check ignores the ones upgrades add.
    static let originalColumns = "id, title, kind, relative_path, body, extraction_note, byte_count, created_at, updated_at, collection_id, favorite"

    @Test func versionOneMigrationPreservesRowsAndIsIdempotent() async throws {
        let root = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("library.sqlite")
        let before: [[String: String]]
        do {
            let old = try Database(url: path)
            try old.execute("DROP INDEX IF EXISTS items_deleted")
            try old.execute("DROP INDEX IF EXISTS items_fingerprint")
            try old.execute("ALTER TABLE items DROP COLUMN image_base_path")
            try old.execute("ALTER TABLE items DROP COLUMN deleted_at")
            try old.execute("ALTER TABLE items DROP COLUMN fingerprint")
            try old.execute("ALTER TABLE items DROP COLUMN ocr_version")
            try old.execute("ALTER TABLE items DROP COLUMN reading_position")
            try old.execute("PRAGMA user_version = 1")
            try old.execute("INSERT INTO collections VALUES ('c', '资料')")
            try old.execute("INSERT INTO items VALUES ('id','旧笔记','note',NULL,'中文原文',NULL,12,100,200,'c',1)")
            try old.execute("INSERT INTO activities VALUES ('a','历史记录',123)")
            before = try old.rows("SELECT \(Self.originalColumns) FROM items")
        }
        for _ in 0..<2 {
            let db = try Database(url: path)
            #expect(try db.rows("PRAGMA user_version").first?["user_version"] == String(Database.schemaVersion))
            #expect(try db.rows("SELECT \(Self.originalColumns) FROM items") == before)
            #expect(try db.rows("SELECT * FROM collections").first?["name"] == "资料")
            #expect(try db.rows("SELECT * FROM activities").first?["message"] == "历史记录")
            #expect(try db.rows("PRAGMA foreign_key_check").isEmpty)
        }
    }

    @Test func importAndDirectorySelectionPersistWithoutChangingContentOrHistory() async throws {
        let root = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.MD")
        try "![图](images/a.png)".write(to: file, atomically: true, encoding: .utf8)
        let library = root.appendingPathComponent("Library")
        let repo = try LibraryRepository(root: library)
        let report = try await repo.importFiles([file])
        let id = try #require(report.importedIDs.first)
        let note = try await repo.saveNote(title: "笔记", body: "![图](a.png)", kind: .note)
        let before = try await repo.snapshot()
        #expect(before.items.first(where: { $0.id == id })?.imageBasePath == root.path)
        let another = root.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: another, withIntermediateDirectories: true)
        try await repo.setImageBaseDirectory(id: id, directory: another)
        try await repo.setImageBaseDirectory(id: note, directory: root)
        await #expect(throws: (any Error).self) { try await repo.setImageBaseDirectory(id: id, directory: file) }
        await #expect(throws: (any Error).self) { try await repo.setImageBaseDirectory(id: "missing", directory: root) }
        await #expect(throws: (any Error).self) { try await repo.setImageBaseDirectory(id: id, directory: URL(string: "https://example.com/")!) }
        let reopened = try LibraryRepository(root: library)
        let after = try await reopened.snapshot()
        #expect(after.items.first(where: { $0.id == id })?.imageBasePath == another.path)
        #expect(after.items.first(where: { $0.id == note })?.imageBasePath == root.path)
        let importedBody = try await repo.body(for: id)
        let noteBody = try await repo.body(for: note)
        #expect(try await reopened.body(for: id) == importedBody)
        #expect(try await reopened.body(for: note) == noteBody)
        #expect(after.items.map(\.updatedAt) == before.items.map(\.updatedAt))
        #expect(after.activities.map(\.id) == before.activities.map(\.id))
    }
}
