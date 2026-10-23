import Foundation
import Testing
@testable import LibraryCore

@Suite(.serialized)
final class LibraryDeletionTests {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("Library") }

    init() throws {
        temporary = testTemporaryDirectory.appendingPathComponent("deletion-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: temporary) }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func svg(_ color: String) -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"10\"><rect width=\"20\" height=\"10\" fill=\"\(color)\"/></svg>"
    }

    @Test func deletionRemovesManagedCopyAndKeepsOriginal() async throws {
        let source = temporary.appendingPathComponent("原始资料.txt")
        try write("需要保留的原文件", to: source)
        let repo = try LibraryRepository(root: root)
        let id = try #require(try await repo.importFiles([source]).importedIDs.first)
        let item = try #require(try await repo.snapshot().items.first)
        let managed = try repo.fileURL(for: item)
        #expect(FileManager.default.fileExists(atPath: managed.path))

        let report = try await repo.delete(ids: [id])

        #expect(report.deleted == 1)
        #expect(report.warnings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: managed.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        let after = try await repo.snapshot()
        #expect(after.items.isEmpty)
        #expect(after.activities.contains { $0.message.contains("删除了") })
    }

    @Test func sharedImageSurvivesUntilItsLastOwnerIsDeleted() async throws {
        let source = temporary.appendingPathComponent("images")
        try write(svg("red"), to: source.appendingPathComponent("a.svg"))
        let repo = try LibraryRepository(root: root)
        let first = try await repo.saveNote(title: "第一份", body: "![a](a.svg)", kind: .note)
        let second = try await repo.saveNote(title: "第二份", body: "![a](a.svg)", kind: .note)
        _ = try await repo.setImageBaseDirectory(id: first, directory: source)
        _ = try await repo.setImageBaseDirectory(id: second, directory: source)
        let state = try await repo.snapshot()
        let attachment = try #require(state.items.first(where: { $0.id == first })?.imageAttachments["a.svg"])
        #expect(FileManager.default.fileExists(atPath: attachment.path))

        _ = try await repo.delete(ids: [first])
        #expect(FileManager.default.fileExists(atPath: attachment.path))

        _ = try await repo.delete(ids: [second])
        #expect(!FileManager.default.fileExists(atPath: attachment.path))
    }

    @Test func batchDeletionReportsCountAndOneActivity() async throws {
        let repo = try LibraryRepository(root: root)
        var ids: [String] = []
        for index in 0..<3 {
            ids.append(try await repo.saveNote(title: "资料 \(index)", body: "正文", kind: .note))
        }
        let report = try await repo.delete(ids: ids)
        #expect(report.deleted == 3)
        #expect(report.warnings.isEmpty)
        let state = try await repo.snapshot()
        #expect(state.items.isEmpty)
        #expect(state.activities.contains { $0.message == "删除了 3 项资料" })
    }

    @Test func deletingUnknownIDsIsANoOp() async throws {
        let repo = try LibraryRepository(root: root)
        let report = try await repo.delete(ids: ["missing", "missing"])
        #expect(report.deleted == 0)
        #expect(report.warnings.isEmpty)
        #expect(try await repo.snapshot().activities.isEmpty)
    }

    @Test func batchFavoriteAndOrganizeUpdateEveryItem() async throws {
        let repo = try LibraryRepository(root: root)
        let collection = try await repo.createCollection(name: "巴西")
        let first = try await repo.saveNote(title: "一", body: "正文", kind: .note)
        let second = try await repo.saveNote(title: "二", body: "正文", kind: .note)
        let ids = [first, second]

        try await repo.setFavorite(ids: ids, value: true)
        try await repo.organize(ids: ids, collectionID: collection)

        let state = try await repo.snapshot()
        #expect(state.items.filter { !$0.favorite }.isEmpty)
        #expect(state.items.allSatisfy { $0.collectionID == collection })
        #expect(state.activities.contains { $0.message == "将 2 项资料归入「巴西」" })
    }

    @Test func organizingIntoAMissingCollectionRollsBackEveryItem() async throws {
        let repo = try LibraryRepository(root: root)
        let collection = try await repo.createCollection(name: "原目录")
        let first = try await repo.saveNote(title: "一", body: "正文", kind: .note, collectionID: collection)
        let second = try await repo.saveNote(title: "二", body: "正文", kind: .note, collectionID: collection)

        await #expect(throws: (any Error).self) {
            try await repo.organize(ids: [first, second], collectionID: "missing")
        }

        let state = try await repo.snapshot()
        #expect(state.items.allSatisfy { $0.collectionID == collection })
        #expect(state.items.count == 2)
    }

    @Test func unsafeManagedPathIsReportedWithoutDeletingOutsideFiles() async throws {
        let source = temporary.appendingPathComponent("资料.txt")
        try write("内容", to: source)
        let repo = try LibraryRepository(root: root)
        let id = try #require(try await repo.importFiles([source]).importedIDs.first)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.txt")
        try write("不要删除", to: outside)

        let database = try Database(url: root.appendingPathComponent("library.sqlite"))
        try database.execute("UPDATE items SET relative_path = '../outside.txt' WHERE id = ?", [id])

        let report = try await repo.delete(ids: [id])
        #expect(report.deleted == 1)
        #expect(report.warnings.count == 1)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}
