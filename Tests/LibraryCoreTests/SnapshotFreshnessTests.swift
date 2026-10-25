import Foundation
import Testing
@testable import LibraryCore

@Suite(.serialized)
struct SnapshotFreshnessTests {
    private func makeRepository() throws -> (LibraryRepository, URL) {
        let root = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try LibraryRepository(root: root), root)
    }

    @Test func changeCounterMovesOnWritesAndStaysPutOnReads() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try await repository.changeCount()
        _ = try await repository.saveNote(title: "笔记", body: "正文", kind: .note)
        let afterWrite = try await repository.changeCount()
        #expect(afterWrite > before)
        _ = try await repository.snapshot()
        #expect(try await repository.changeCount() == afterWrite)
        _ = try await repository.snapshot()
        #expect(try await repository.changeCount() == afterWrite)
    }

    @Test func previewAndFlagsComeFromTheRowNotTheBody() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = try await repository.saveNote(title: "纯正文", body: "只有文字", kind: .note)
        let linked = try await repository.saveNote(
            title: "带链接",
            body: "参考 [文档](https://example.com/doc)",
            kind: .note)
        let empty = try await repository.saveNote(title: "空正文", body: "   ", kind: .note)
        let snapshot = try await repository.snapshot()
        let byID = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        #expect(byID[plain]?.preview == "只有文字")
        #expect(byID[plain]?.hasBody == true)
        #expect(byID[plain]?.hasLinks == false)
        #expect(byID[linked]?.hasLinks == true)
        #expect(byID[empty]?.hasBody == false)
        #expect(byID[empty]?.preview == "   ")
    }

    @Test func editingTheBodyRefreshesThePreview() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await repository.saveNote(title: "笔记", body: "第一版", kind: .note)
        _ = try await repository.saveNote(id: id, title: "笔记", body: "第二版 [链接](https://example.com)", kind: .note)
        let snapshot = try await repository.snapshot()
        let item = snapshot.items.first { $0.id == id }
        #expect(item?.preview == "第二版 [链接](https://example.com)")
        #expect(item?.hasLinks == true)
    }

    @Test func backfillFillsRowsWrittenBeforeTheColumnsExisted() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await repository.saveNote(
            title: "旧笔记",
            body: "老正文 [链接](https://example.com)",
            kind: .note)
        // Pretend the row predates the derived columns: the triggers only fire on
        // writes, so blanking them simulates an upgraded library.
        let database = try Database(url: root.appendingPathComponent("library.sqlite"))
        try database.execute(
            "UPDATE items SET preview = NULL, has_body = 0, has_links = 0 WHERE id = ?", [id])

        #expect(try await repository.backfillDerived() == 1)
        let filled = try await repository.snapshot().items.first { $0.id == id }
        #expect(filled?.preview == "老正文 [链接](https://example.com)")
        #expect(filled?.hasBody == true)
        #expect(filled?.hasLinks == true)
        #expect(try await repository.backfillDerived() == 0)
    }
}
