import Foundation
import Testing
@testable import LibraryCore

struct MarkdownAttachmentTests {
    @Test func literalPercentAndMalformedNeighbourDoNotDiscardValidImagesOrBlockNotes() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try write(svg("red"), source.appendingPathComponent("good.svg"))
        try write(svg("blue"), source.appendingPathComponent("100%.svg"))
        let body = "![good](good.svg) ![percent](100%.svg) ![invalid](http://[)"
        let file = source.appendingPathComponent("guide.md")
        try write(body, file)
        let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
        let report = try await repo.importFiles([file])
        #expect(report.importedIDs.count == 1 && report.warnings.count == 1)
        let document = try #require(try await repo.snapshot().items.first)
        #expect(document.imageAttachments.count == 2)
        #expect(document.imageAttachments["100%25.svg"] != nil)
        let id = try await repo.saveNote(title: "允许修正的笔记", body: body, kind: .note)
        let selected = try await repo.setImageBaseDirectory(id: id, directory: source)
        #expect(selected.saved == 2 && selected.failures.count == 1)
        let note = try #require(try await repo.snapshot().items.first(where: { $0.id == id }))
        #expect(try await repo.body(for: id) == body && note.imageAttachments.count == 2 && note.imageAttachmentIssues.count == 1)
    }

    private func workspace() throws -> URL {
        let root = testTemporaryDirectory.appendingPathComponent("attachments-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func svg(_ color: String) -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"10\"><rect width=\"20\" height=\"10\" fill=\"\(color)\"/></svg>"
    }

    @Test func sourceAndLibraryCanMoveWithAllReferenceFormsAndDeduplicatedCopies() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let image = source.appendingPathComponent("images/中文 图片.svg")
        try write(svg("red"), image)
        let file = source.appendingPathComponent("docs/guide.md")
        let body = """
        ![relative](../images/中文%20图片.svg)
        inline ![reference][asset] end.

        [asset]: ../images/中文%20图片.svg

        ![absolute](<\(image.path)>)
        ![file](\(image.absoluteString))

        /imgstart:中文 图片.svg:imgend/

        `![not an image](missing-code.svg)`

        ```markdown
        ![code](missing-fence.svg)
        ```
        """
        try write(body, file)
        let library = root.appendingPathComponent("Library")
        var id = ""
        do {
            let repo = try LibraryRepository(root: library)
            let report = try await repo.importFiles([file])
            id = try #require(report.importedIDs.first)
            #expect(report.failures.isEmpty && report.warnings.isEmpty)
            let item = try #require(try await repo.snapshot().items.first)
            #expect(item.imageAttachments.count == 4)
            #expect(Set(item.imageAttachments.values).count == 1)
            #expect(try String(contentsOf: repo.fileURL(for: item)) == body)
        }
        // Only this test's sources and library move; production sources are untouched.
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("source-moved"))
        let relocated = root.appendingPathComponent("Library-moved")
        try FileManager.default.moveItem(at: library, to: relocated)
        let reopened = try LibraryRepository(root: relocated)
        let item = try #require(try await reopened.snapshot().items.first)
        let context = MarkdownImageContext(itemID: id, basePath: item.imageBasePath, attachments: item.imageAttachments)
        for reference in try MarkdownImageSource.references(in: body).urls {
            let saved = try context.resolve(reference)
            #expect(saved.path.hasPrefix(relocated.path))
            #expect(try String(contentsOf: saved) == svg("red"))
        }
        let repeatCopy = try await reopened.copyMarkdownImages(id: id)
        #expect(repeatCopy.copied == 0 && repeatCopy.reused == 4 && repeatCopy.failures.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: relocated.appendingPathComponent("Attachments").path).count == 1)
    }

    @Test func noteEditsPreserveArchivedContentAndDirectoryRefreshUpdatesOnlyAvailableImages() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try write(svg("red"), source.appendingPathComponent("a.svg"))
        let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
        let id = try await repo.saveNote(title: "笔记", body: "![a](a.svg)", kind: .note)
        #expect(try await repo.snapshot().items.first?.imageAttachmentIssues.count == 1)
        let selected = try await repo.setImageBaseDirectory(id: id, directory: source)
        #expect(selected.copied == 1 && selected.failures.isEmpty)
        let before = try #require(try await repo.snapshot().items.first)
        let saved = try #require(before.imageAttachments["a.svg"])
        try write(svg("blue"), source.appendingPathComponent("a.svg"))
        try write(svg("green"), source.appendingPathComponent("b.svg"))
        try await repo.saveNote(id: id, title: "笔记", body: "编辑正文 ![a](a.svg) 和 ![b](b.svg)", kind: .note)
        let edited = try #require(try await repo.snapshot().items.first)
        #expect(edited.imageAttachments["a.svg"] == saved)
        #expect(edited.imageAttachments.count == 2)
        #expect(try String(contentsOf: saved) == svg("red"))
        try FileManager.default.removeItem(at: source.appendingPathComponent("b.svg"))
        let refreshed = try await repo.setImageBaseDirectory(id: id, directory: source)
        #expect(refreshed.failures.count == 1 && refreshed.saved == 2)
        let updated = try #require(try await repo.snapshot().items.first)
        #expect(try String(contentsOf: #require(updated.imageAttachments["a.svg"])) == svg("blue"))
        #expect(updated.imageAttachments["b.svg"] == edited.imageAttachments["b.svg"])
        #expect(updated.imageAttachmentIssues.count == 1)
    }

    @Test func missingAndRemoteImagesDoNotLoseSuccessfulCopiesOrConfuseSameNames() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
        for color in ["red", "blue"] {
            let directory = root.appendingPathComponent(color)
            try write(svg(color), directory.appendingPathComponent("a.svg"))
            let body = "![a](a.svg) ![missing](missing.svg) ![remote](http://127.0.0.1:9/probe.png) ![host](file://remote/a.svg)"
            let file = directory.appendingPathComponent("guide.md")
            try write(body, file)
            let report = try await repo.importFiles([file])
            #expect(report.importedIDs.count == 1 && report.failures.isEmpty && report.warnings.count == 1)
        }
        let items = try await repo.snapshot().items
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.imageAttachments.count == 1 && $0.imageAttachmentIssues.count == 1 })
        #expect(Set(items.compactMap { $0.imageAttachments["a.svg"] }).count == 2)
        let colors = try Set(items.compactMap { $0.imageAttachments["a.svg"] }.map { try String(contentsOf: $0) })
        #expect(colors == Set([svg("red"), svg("blue")]))
    }

    @Test func failedTransactionsKeepOldMappingsAndRemoveOnlyNewUncommittedFiles() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let library = root.appendingPathComponent("Library")
        try write(svg("red"), source.appendingPathComponent("a.svg"))
        try write(svg("blue"), source.appendingPathComponent("b.svg"))
        let repo = try LibraryRepository(root: library)
        let id = try await repo.saveNote(title: "原笔记", body: "![a](a.svg)", kind: .note)
        try await repo.setImageBaseDirectory(id: id, directory: source)
        let before = try #require(try await repo.snapshot().items.first)
        let database = try Database(url: library.appendingPathComponent("library.sqlite"))
        try database.execute("CREATE TRIGGER reject_images BEFORE INSERT ON markdown_images BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        await #expect(throws: (any Error).self) {
            try await repo.saveNote(id: id, title: "更改", body: "![a](a.svg) ![b](b.svg)", kind: .note)
        }
        let after = try #require(try await repo.snapshot().items.first)
        #expect(after.title == before.title && after.updatedAt == before.updatedAt)
        #expect(try await repo.body(for: id) == "![a](a.svg)")
        #expect(after.imageAttachments == before.imageAttachments)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.appendingPathComponent("Attachments").path).count == 1)
        let file = source.appendingPathComponent("new.md")
        try write("![a](a.svg) ![b](b.svg)", file)
        let rejectedImport = try await repo.importFiles([file])
        #expect(rejectedImport.importedIDs.isEmpty && rejectedImport.failures.count == 1)
        #expect(try await repo.snapshot().items.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.appendingPathComponent("Files").path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.appendingPathComponent("Attachments").path).count == 1)
        #expect(try String(contentsOf: source.appendingPathComponent("b.svg")) == svg("blue"))
    }

    @Test func versionTwoBackfillIsIdempotentPreservesRowsAndScansBeyondSearchLimit() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let library = root.appendingPathComponent("Library")
        try write(svg("red"), source.appendingPathComponent("tail.svg"))
        let body = String(repeating: "x", count: TextExtractor.maximumCharacters + 100) + "\n\n![tail](tail.svg)"
        let file = source.appendingPathComponent("long.md")
        try write(body, file)
        let repo = try LibraryRepository(root: library)
        let report = try await repo.importFiles([file])
        let id = try #require(report.importedIDs.first)
        #expect(report.warnings.isEmpty)
        let imported = try #require(try await repo.snapshot().items.first)
        #expect(try await repo.body(for: id)?.count == TextExtractor.maximumCharacters)
        #expect(imported.imageAttachments.count == 1)
        let db = try Database(url: library.appendingPathComponent("library.sqlite"))
        let before = try db.rows("SELECT * FROM items")
        let history = try db.rows("SELECT * FROM activities")
        try db.execute("DROP TABLE markdown_images")
        try db.execute("PRAGMA user_version = 2")
        let reopened = try LibraryRepository(root: library)
        let restored = try await reopened.copyMarkdownImages(id: id)
        let repeated = try await reopened.copyMarkdownImages(id: id)
        #expect(restored.reused == 1 && repeated.reused == 1 && repeated.copied == 0)
        #expect(try db.rows("SELECT * FROM items") == before)
        #expect(try db.rows("SELECT * FROM activities") == history)
        #expect(try db.rows("PRAGMA user_version").first?["user_version"] == String(Database.schemaVersion))
        #expect(try db.rows("PRAGMA foreign_key_check").isEmpty)
    }

    @Test func unsafeOrOversizedFilesAndBrokenArchivedCopiesAreReported() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try write(svg("red"), source.appendingPathComponent("good.svg"))
        let huge = source.appendingPathComponent("large.png")
        #expect(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(MarkdownAttachments.maximumBytes + 1)); try handle.close()
        try FileManager.default.createDirectory(at: source.appendingPathComponent("directory.png"), withIntermediateDirectories: true)
        let file = source.appendingPathComponent("guide.md")
        try write("![good](good.svg) ![large](large.png) ![dir](directory.png)", file)
        let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
        let report = try await repo.importFiles([file])
        #expect(report.warnings.count == 2 && report.importedIDs.count == 1)
        let item = try #require(try await repo.snapshot().items.first)
        let archived = try #require(item.imageAttachments["good.svg"])
        try write("broken", archived)
        let repair = try await repo.copyMarkdownImages(id: item.id)
        #expect(repair.failures.count == 3)
        #expect(try String(contentsOf: archived) == "broken") // Never silently overwrite corruption.
        #expect(try String(contentsOf: source.appendingPathComponent("good.svg")) == svg("red"))
    }
}
