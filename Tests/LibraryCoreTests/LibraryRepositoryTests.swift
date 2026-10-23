import Testing
import AppKit
import CoreText
@testable import LibraryCore

@Suite(.serialized)
final class LibraryRepositoryTests {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("Library") }

    init() throws {
        temporary = testTemporaryDirectory.appendingPathComponent("personal-library-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: temporary) }

    private func fixture(_ name: String, text: String) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func testNotesCollectionsAndFavoritesPersistAcrossReopen() async throws {
        let repo = try LibraryRepository(root: root)
        let collection = try await repo.createCollection(name: "巴西 Energisa")
        let id = try await repo.saveNote(title: "项目记录", body: "计量协议与交付材料", kind: .note, collectionID: collection)
        try await repo.setFavorite(id: id, value: true)
        let reopened = try LibraryRepository(root: root)
        let state = try await reopened.snapshot()
        #expect(state.items.count == 1)
        #expect(state.items[0].text == "计量协议与交付材料")
        #expect(state.items[0].collectionID == collection)
        #expect(state.items[0].favorite)
        #expect(state.collections[0].name == "巴西 Energisa")
        #expect(state.activities.count == 2)
    }

    @Test func testImportCopiesSourceAndSearchesChineseBody() async throws {
        let source = try fixture("交付说明.md", text: "## 合同\n巴西客户的现场验收，Energia elétrica。")
        let original = try Data(contentsOf: source)
        let repo = try LibraryRepository(root: root)
        let report = try await repo.importFiles([source])
        #expect(report.importedIDs.count == 1)
        #expect(report.failures.isEmpty)
        let state = try await repo.snapshot()
        let item = try #require(state.items.first)
        #expect(try Data(contentsOf: source) == original)
        let managed = try repo.fileURL(for: item)
        #expect(managed != source)
        #expect(try Data(contentsOf: managed) == original)
        #expect(LibrarySearch.matches(item, query: "巴西 验收"))
        #expect(LibrarySearch.matches(item, query: "energia ELETRICA"))
        #expect(!(LibrarySearch.matches(item, query: "巴西 香港")))
        #expect(LibrarySearch.excerpt(item.text, query: "验收").contains("验收"))
    }

    @Test func testSameNameImportsKeepSeparateCopies() async throws {
        let source = try fixture("资料.txt", text: "第一份内容")
        let repo = try LibraryRepository(root: root)
        _ = try await repo.importFiles([source])
        try "更新后的内容".write(to: source, atomically: true, encoding: .utf8)
        _ = try await repo.importFiles([source])
        let state = try await repo.snapshot()
        #expect(state.items.count == 2)
        #expect(Set(state.items.compactMap(\.relativePath)).count == 2)
        #expect(Set(state.items.map(\.text)) == Set(["第一份内容", "更新后的内容"]))
    }

    @Test func testPartialImportReportsInvalidPathsWithoutLosingGoodFiles() async throws {
        let source = try fixture("valid.txt", text: "有效内容")
        let repo = try LibraryRepository(root: root)
        let report = try await repo.importFiles([temporary, source, temporary.appendingPathComponent("missing.txt")])
        #expect(report.importedIDs.count == 1)
        #expect(report.failures.count == 2)
        let state = try await repo.snapshot()
        #expect(state.items.count == 1)
    }

    @Test func testWordDocumentExtractsRealChineseText() async throws {
        let source = try fixture("word-input.txt", text: "巴西项目的交付文档。Energisa acceptance evidence.")
        let docx = temporary.appendingPathComponent("现场验收.docx")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "docx", "-output", docx.path, source.path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let repo = try LibraryRepository(root: root)
        let report = try await repo.importFiles([docx])
        #expect(report.failures.isEmpty)
        let state = try await repo.snapshot()
        let item = try #require(state.items.first)
        #expect(item.kind == .document)
        #expect(item.extractionNote == nil)
        #expect(LibrarySearch.matches(item, query: "巴西 交付"))
    }

    @Test func testPDFExtractsTextLayer() async throws {
        let pdf = temporary.appendingPathComponent("sample.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        let consumer = try #require(CGDataConsumer(url: pdf as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 40, y: 500)
        let text = NSAttributedString(string: "Brazil Energia acceptance", attributes: [.font: NSFont.systemFont(ofSize: 18)])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage(); context.closePDF()
        let repo = try LibraryRepository(root: root)
        _ = try await repo.importFiles([pdf])
        let state = try await repo.snapshot()
        #expect(LibrarySearch.matches(try #require(state.items.first), query: "Brazil acceptance"))
        #expect(state.items[0].extractionNote == nil)
    }

    @Test func testUnreadableDocumentAndUnknownTypeRemainAvailableWithNotice() async throws {
        let broken = try fixture("broken.pdf", text: "not a PDF")
        let unknown = try fixture("archive.unsupported", text: "cannot index this")
        let repo = try LibraryRepository(root: root)
        let report = try await repo.importFiles([broken, unknown])
        #expect(report.importedIDs.count == 2)
        let state = try await repo.snapshot()
        #expect(state.items.allSatisfy { $0.extractionNote != nil && $0.text.isEmpty })
        for item in state.items { #expect(FileManager.default.fileExists(atPath: try repo.fileURL(for: item).path)) }
    }

    @Test func testFailedImportTransactionRemovesOnlyItsCopy() async throws {
        let source = try fixture("keep-original.txt", text: "必须保留的源文件")
        let repo = try LibraryRepository(root: root)
        let database = try Database(url: root.appendingPathComponent("library.sqlite"))
        try database.execute("CREATE TRIGGER reject_activity BEFORE INSERT ON activities BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        let report = try await repo.importFiles([source])
        #expect(report.failures.count == 1)
        let state = try await repo.snapshot()
        #expect(state.items.isEmpty)
        #expect(state.activities.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Files").path).isEmpty)
        #expect(try String(contentsOf: source) == "必须保留的源文件")
    }

    @Test func testInvalidCollectionRollsBackAndDuplicateNameFails() async throws {
        let repo = try LibraryRepository(root: root)
        _ = try await repo.createCollection(name: "工作")
        do { _ = try await repo.createCollection(name: " 工作 "); Issue.record("Should reject duplicate") } catch {}
        let id = try await repo.saveNote(title: "测试笔记", body: "保持原状", kind: .note)
        do { try await repo.organize(id: id, collectionID: "missing"); Issue.record("Should reject missing collection") } catch {}
        let state = try await repo.snapshot()
        #expect(state.collections.count == 1)
        #expect(state.items[0].collectionID == nil)
        #expect(state.activities.count == 2)
    }

    @Test func testNoteEditPreservesCollectionAndNULCharacters() async throws {
        let repo = try LibraryRepository(root: root)
        let collection = try await repo.createCollection(name: "生活")
        let id = try await repo.saveNote(title: "想法", body: "原文", kind: .thought, collectionID: collection)
        _ = try await repo.saveNote(id: id, title: "新想法", body: "开头\0末尾", kind: .thought)
        let state = try await repo.snapshot()
        #expect(state.items[0].text == "开头\0末尾")
        #expect(state.items[0].title == "新想法")
        #expect(state.items[0].collectionID == collection)
    }

    @Test func testCorruptDatabaseFailsWithoutOverwriting() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("library.sqlite")
        let sentinel = Data("this is not a sqlite database".utf8)
        try sentinel.write(to: url)
        #expect(throws: (any Error).self) { try LibraryRepository(root: root) }
        #expect(try Data(contentsOf: url) == sentinel)
    }

    @Test func testManagedPathTraversalAndMissingFileAreRejected() async throws {
        let source = try fixture("safe.txt", text: "safe")
        let repo = try LibraryRepository(root: root)
        _ = try await repo.importFiles([source])
        let database = try Database(url: root.appendingPathComponent("library.sqlite"))
        try database.execute("UPDATE items SET relative_path = '../outside.txt'")
        var state = try await repo.snapshot()
        #expect(throws: (any Error).self) { try repo.fileURL(for: state.items[0]) }
        try database.execute("UPDATE items SET relative_path = 'missing.txt'")
        state = try await repo.snapshot()
        #expect(throws: (any Error).self) { try repo.fileURL(for: state.items[0]) }
    }

    @Test func testExtractionLimitIsVisibleAndOriginalIsComplete() async throws {
        let content = String(repeating: "巴西", count: 1_000_010)
        let source = try fixture("large.txt", text: content)
        let repo = try LibraryRepository(root: root)
        _ = try await repo.importFiles([source])
        let state = try await repo.snapshot()
        let item = try #require(state.items.first)
        #expect(item.text.count == 2_000_000)
        #expect(item.extractionNote != nil)
        #expect(try String(contentsOf: repo.fileURL(for: item)).count == content.count)
    }

    @Test func testExcerptUsesFirstTermThatActuallyMatchesBody() {
        let text = String(repeating: "前言", count: 250) + "现场验收内容"
        let excerpt = LibrarySearch.excerpt(text, query: "巴西 验收")
        #expect(excerpt.contains("验收"))
        #expect(excerpt.hasPrefix("…"))
    }
}
