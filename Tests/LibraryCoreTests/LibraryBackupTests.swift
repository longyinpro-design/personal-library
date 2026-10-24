import Foundation
import Testing
@testable import LibraryCore

@Suite(.serialized)
final class LibraryBackupTests {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("Library") }

    init() throws {
        temporary = testTemporaryDirectory.appendingPathComponent("backup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: temporary) }

    private func write(_ text: String, named name: String) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Opens a backup file as if it were the whole library, the way a user would
    /// point `--library-path` at a restored folder.
    private func openAsLibrary(_ backup: URL, name: String) throws -> LibraryRepository {
        let folder = temporary.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = folder.appendingPathComponent(LibraryBackupStore.databaseName)
        try FileManager.default.copyItem(at: backup, to: database)
        let wal = URL(fileURLWithPath: backup.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            try FileManager.default.copyItem(at: wal, to: URL(fileURLWithPath: database.path + "-wal"))
        }
        return try LibraryRepository(root: folder)
    }

    @Test func backupOpensAsAFreshLibraryAndPassesIntegrityCheck() async throws {
        let repo = try LibraryRepository(root: root)
        let source = try write("备份里的正文", named: "资料一.txt")
        _ = try await repo.importFiles([source])
        let live = try await repo.snapshot()

        let backup = try await repo.createBackup()

        let contents = try LibraryBackupStore.inspect(backup.url)
        #expect(contents.itemCount == live.items.count)
        #expect(contents.schemaVersion >= 1)

        let restored = try openAsLibrary(backup.url, name: "fresh")
        let snapshot = try await restored.snapshot()
        #expect(snapshot.items.map(\.id) == live.items.map(\.id))
    }

    @Test func pruningKeepsTheNewestSevenBackups() async throws {
        let repo = try LibraryRepository(root: root)
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        for hour in 0..<9 {
            try await repo.createBackup(at: start.addingTimeInterval(Double(hour) * 3600))
        }

        let backups = try await repo.backups()

        #expect(backups.count == LibraryBackupStore.retention)
        #expect(backups.first?.date == start.addingTimeInterval(8 * 3600))
        #expect(backups.last?.date == start.addingTimeInterval(2 * 3600))
    }

    @Test func restoreAppliesAtNextLaunchAndKeepsThePreviousDatabase() async throws {
        let repo = try LibraryRepository(root: root)
        _ = try await repo.importFiles([try write("第一份", named: "资料一.txt")])
        let before = try await repo.snapshot()
        let backup = try await repo.createBackup()
        _ = try await repo.importFiles([try write("第二份", named: "资料二.txt")])
        #expect(try await repo.snapshot().items.count == 2)

        try LibraryBackupStore.stageRestore(from: backup.url, in: root)
        #expect(LibraryBackupStore.pendingRestore(in: root) != nil)
        let applied = try LibraryBackupStore.applyPendingRestore(in: root)

        #expect(applied)
        #expect(LibraryBackupStore.pendingRestore(in: root) == nil)
        let safety = root.appendingPathComponent(LibraryBackupStore.safetyCopyName)
        #expect(FileManager.default.fileExists(atPath: safety.path))

        let reopened = try LibraryRepository(root: root)
        #expect(try await reopened.snapshot().items.map(\.id) == before.items.map(\.id))

        let previous = try openAsLibrary(safety, name: "previous")
        #expect(try await previous.snapshot().items.count == 2)
    }

    @Test func stagingRejectsAFileThatIsNotABackup() async throws {
        let repo = try LibraryRepository(root: root)
        _ = try await repo.importFiles([try write("原始资料", named: "资料一.txt")])
        let before = try await repo.snapshot()
        let notABackup = try write("这只是一段文本", named: "笔记.txt")

        #expect(throws: (any Error).self) {
            try LibraryBackupStore.stageRestore(from: notABackup, in: root)
        }
        #expect(LibraryBackupStore.pendingRestore(in: root) == nil)
        #expect(try await repo.snapshot().items.map(\.id) == before.items.map(\.id))
    }

    @Test func cancellingAStagedRestoreLeavesTheLiveDatabaseAlone() async throws {
        let repo = try LibraryRepository(root: root)
        _ = try await repo.importFiles([try write("第一份", named: "资料一.txt")])
        let backup = try await repo.createBackup()
        _ = try await repo.importFiles([try write("第二份", named: "资料二.txt")])
        let live = try await repo.snapshot()

        try LibraryBackupStore.stageRestore(from: backup.url, in: root)
        try LibraryBackupStore.cancelPendingRestore(in: root)

        #expect(LibraryBackupStore.pendingRestore(in: root) == nil)
        #expect(try await repo.snapshot().items.map(\.id) == live.items.map(\.id))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(LibraryBackupStore.safetyCopyName).path))
    }
}
