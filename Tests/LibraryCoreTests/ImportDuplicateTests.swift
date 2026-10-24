import Foundation
import Testing
@testable import LibraryCore

@Suite(.serialized)
final class ImportDuplicateTests {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("Library") }

    init() throws {
        temporary = testTemporaryDirectory.appendingPathComponent("duplicate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: temporary) }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func importingTheSameBytesAgainIsReportedAsACopy() async throws {
        let source = try write("# 说明\n\n同一份内容", to: "手册.md")
        let repo = try LibraryRepository(root: root)
        _ = try await repo.importFiles([source])

        var preview = try await repo.previewImport([source])
        #expect(preview.hasDuplicates)
        #expect(preview.existingCopyCount == 1)
        #expect(preview.duplicates.first?.existing.first?.title == "手册.md")

        let skipped = try await repo.importFiles(preview, skippingDuplicates: true)
        #expect(skipped.importedIDs.isEmpty)
        #expect(skipped.skipped == ["手册.md"])

        preview = try await repo.previewImport([source])
        let kept = try await repo.importFiles(preview, skippingDuplicates: false)
        #expect(kept.importedIDs.count == 1)
        let snapshot = try await repo.snapshot()
        #expect(snapshot.items.count == 2)
        #expect(Set(snapshot.items.map(\.title)) == ["手册.md"])
    }

    @Test func sameNameWithDifferentContentIsNotADuplicate() async throws {
        let first = try write("第一版正文", to: "笔记.md")
        let repo = try LibraryRepository(root: root)
        _ = try await repo.importFiles([first])

        let second = try write("完全不同的正文", to: "另一处/笔记.md")
        let preview = try await repo.previewImport([second])
        #expect(!preview.hasDuplicates)
        #expect(preview.pending.first?.existing.isEmpty == true)
        #expect(try await repo.importFiles(preview, skippingDuplicates: true).importedIDs.count == 1)
    }

    @Test func batchImportAggregatesDuplicatesAndRepeatsInOnePreview() async throws {
        let existing = try write("已经导入过", to: "旧.md")
        let fresh = try write("全新的内容", to: "新.md")
        let repo = try LibraryRepository(root: root)
        _ = try await repo.importFiles([existing])

        let preview = try await repo.previewImport([existing, fresh, existing])
        #expect(preview.pending.count == 3)
        #expect(preview.duplicates.count == 2)
        #expect(preview.failures.isEmpty)
        // The second pick of the old file is both in the library and repeated here.
        #expect(preview.duplicates.filter { $0.repeatedInBatch }.count == 1)

        let report = try await repo.importFiles(preview, skippingDuplicates: true)
        #expect(report.importedIDs.count == 1)
        #expect(report.skipped.count == 2)
        #expect(try await repo.snapshot().items.count == 2)
    }

    @Test func previewReportsUnreadableFilesWithoutStoppingTheRest() async throws {
        let good = try write("能读的", to: "好.md")
        let missing = temporary.appendingPathComponent("不存在.md")
        let repo = try LibraryRepository(root: root)

        let preview = try await repo.previewImport([good, missing])
        #expect(preview.pending.count == 1)
        #expect(preview.failures.count == 1)
        #expect(preview.failures.first?.contains("不存在.md") == true)

        let report = try await repo.importFiles(preview, skippingDuplicates: false)
        #expect(report.importedIDs.count == 1)
        #expect(report.failures.count == 1)
    }

    @Test func backfillGivesOlderItemsAFingerprintSoTheyTakePart() async throws {
        let source = try write("升级前导入的文件", to: "老资料.md")
        let repo = try LibraryRepository(root: root)
        let id = try #require(try await repo.importFiles([source]).importedIDs.first)

        // Simulate an item imported before version 7.
        let database = try Database(url: root.appendingPathComponent("library.sqlite"))
        try database.execute("UPDATE items SET fingerprint = NULL WHERE id = ?", [id])
        let previewBefore = try await repo.previewImport([source])
        #expect(!previewBefore.hasDuplicates)

        #expect(try await repo.backfillFingerprints() == 1)
        #expect(try await repo.backfillFingerprints() == 0)
        let previewAfter = try await repo.previewImport([source])
        #expect(previewAfter.hasDuplicates)
        #expect(previewAfter.duplicates.first?.existing.first?.id == id)
    }

    @Test func trashedCopiesDoNotCountAsDuplicates() async throws {
        let source = try write("被删掉的副本", to: "回收.md")
        let repo = try LibraryRepository(root: root)
        let id = try #require(try await repo.importFiles([source]).importedIDs.first)
        #expect(try await repo.moveToTrash(ids: [id]) == 1)

        let preview = try await repo.previewImport([source])
        #expect(!preview.hasDuplicates)
        #expect(try await repo.importFiles(preview, skippingDuplicates: false).importedIDs.count == 1)
    }
}
