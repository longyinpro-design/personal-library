import Foundation
import Testing
@testable import LibraryCore

@Suite(.serialized)
final class LibraryTrashTests {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("Library") }

    init() throws {
        temporary = testTemporaryDirectory.appendingPathComponent("trash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: temporary) }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func trashingKeepsRowCopyAndImagesUntilRestored() async throws {
        let source = temporary.appendingPathComponent("原始资料.md")
        try write("# 标题\n\n正文内容", to: source)
        let repo = try LibraryRepository(root: root)
        let id = try #require(try await repo.importFiles([source]).importedIDs.first)
        let item = try #require(try await repo.snapshot().items.first)
        let managed = try repo.fileURL(for: item)

        #expect(try await repo.moveToTrash(ids: [id]) == 1)
        let trashed = try await repo.snapshot()
        #expect(trashed.items.isEmpty)
        #expect(trashed.trashed.map(\.id) == [id])
        #expect(trashed.activities.first?.message == "将「\(item.title)」移到回收站")
        #expect(FileManager.default.fileExists(atPath: managed.path))
        #expect(FileManager.default.fileExists(atPath: source.path))

        #expect(try await repo.moveToTrash(ids: [id]) == 0)
        #expect(try await repo.restoreFromTrash(ids: [id]) == 1)
        let restored = try await repo.snapshot()
        #expect(restored.trashed.isEmpty)
        #expect(restored.items.map(\.id) == [id])
        #expect(restored.activities.first?.message == "恢复了「\(item.title)」")
        #expect(FileManager.default.fileExists(atPath: managed.path))
    }

    @Test func trashedRowsStayOutOfSearchAndScopeFilters() async throws {
        let repo = try LibraryRepository(root: root)
        let kept = try await repo.saveNote(title: "检索词 保留", body: "检索词 正文", kind: .note)
        let dropped = try await repo.saveNote(title: "检索词 回收", body: "检索词 正文", kind: .note)
        _ = try await repo.moveToTrash(ids: [dropped])

        #expect(try await repo.search(query: "检索词").items.map(\.id) == [kept])
        #expect(try await repo.search(query: "回收").items.isEmpty)
        var inbox = LibrarySearchFilter()
        inbox.inboxOnly = true
        #expect(try await repo.search(query: "检索词", filter: inbox).items.map(\.id) == [kept])
    }

    @Test func permanentDeletionOnlyRunsOnTrashedRowsAndDropsCopies() async throws {
        let source = temporary.appendingPathComponent("回收资料.txt")
        try write("要被彻底删除的副本", to: source)
        let repo = try LibraryRepository(root: root)
        let id = try #require(try await repo.importFiles([source]).importedIDs.first)
        let item = try #require(try await repo.snapshot().items.first)
        let managed = try repo.fileURL(for: item)

        #expect(try await repo.permanentlyDelete(ids: [id]).deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: managed.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        let after = try await repo.snapshot()
        #expect(after.items.isEmpty && after.trashed.isEmpty)
    }

    @Test func emptyTrashClearsEverythingAtOnce() async throws {
        let repo = try LibraryRepository(root: root)
        var ids: [String] = []
        for index in 0..<3 {
            ids.append(try await repo.saveNote(title: "资料 \(index)", body: "正文", kind: .note))
        }
        let kept = try await repo.saveNote(title: "没被删除", body: "正文", kind: .note)
        _ = try await repo.moveToTrash(ids: ids)

        let report = try await repo.emptyTrash()

        #expect(report.deleted == 3)
        #expect(report.warnings.isEmpty)
        let after = try await repo.snapshot()
        #expect(after.trashed.isEmpty)
        #expect(after.items.map(\.id) == [kept])
    }

    @Test func purgeOnlyRemovesRowsPastTheRetentionWindow() async throws {
        let repo = try LibraryRepository(root: root)
        let recent = try await repo.saveNote(title: "刚删除", body: "正文", kind: .note)
        _ = try await repo.moveToTrash(ids: [recent])

        #expect(try await repo.purgeExpiredTrash().deleted == 0)
        #expect(try await repo.snapshot().trashed.count == 1)

        // A negative window puts the cutoff in the future, so every trashed row is old.
        #expect(try await repo.purgeExpiredTrash(olderThan: -1).deleted == 1)
        #expect(try await repo.snapshot().trashed.isEmpty)
    }

    @Test func reopeningTheLibraryKeepsTrashedRows() async throws {
        let repo = try LibraryRepository(root: root)
        let id = try await repo.saveNote(title: "跨启动保留", body: "正文", kind: .note)
        _ = try await repo.moveToTrash(ids: [id])

        let reopened = try LibraryRepository(root: root)
        let state = try await reopened.snapshot()
        #expect(state.items.isEmpty)
        #expect(state.trashed.map(\.title) == ["跨启动保留"])
        #expect(try await reopened.restoreFromTrash(ids: [id]) == 1)
        #expect(try await reopened.snapshot().items.map(\.id) == [id])
    }
}
