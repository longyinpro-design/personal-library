import Foundation
import Testing
@testable import LibraryCore

struct MarkdownLinkTests {
    private func item(_ id: String, source: String) -> LibraryItem {
        LibraryItem(id: id, title: URL(fileURLWithPath: source).lastPathComponent, kind: .document,
                    relativePath: "\(id).md", text: "# 内容", extractionNote: nil, byteCount: 0,
                    createdAt: .distantPast, updatedAt: .distantPast, collectionID: nil, favorite: false,
                    sourcePaths: [source])
    }

    @Test func sourceIdentitySurvivesOriginalAndWholeLibraryMoves() async throws {
        let temp = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = temp.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let first = source.appendingPathComponent("目录.md"), second = source.appendingPathComponent("业务 100%.md")
        try "[业务](业务%20100%25.md#中文标题)".write(to: first, atomically: true, encoding: .utf8)
        try "# 中文标题".write(to: second, atomically: true, encoding: .utf8)
        let root = temp.appendingPathComponent("Library")
        var ids: [String] = []
        do {
            let repo = try LibraryRepository(root: root)
            ids = try await repo.importFiles([first, second]).importedIDs
            #expect(ids.count == 2)
        }
        try FileManager.default.moveItem(at: source, to: temp.appendingPathComponent("source-moved"))
        let moved = temp.appendingPathComponent("Library-moved")
        try FileManager.default.moveItem(at: root, to: moved)
        let repo = try LibraryRepository(root: moved)
        let items = try await repo.snapshot().items
        let a = try #require(items.first { $0.id == ids[0] })
        let b = try #require(items.first { $0.id == ids[1] })
        #expect(a.sourcePaths == [first.path])
        #expect(try MarkdownLinks.resolve(URL(string: "%E4%B8%9A%E5%8A%A1%20100%25.md#%E4%B8%AD%E6%96%87%E6%A0%87%E9%A2%98")!, from: a, items: items, root: moved) == .item(id: b.id, fragment: "中文标题"))
        #expect(try MarkdownLinks.resolve(second, from: a, items: items, root: moved) == .item(id: b.id, fragment: nil))
        #expect(try String(contentsOf: repo.fileURL(for: b), encoding: .utf8) == "# 中文标题")
    }

    @Test func exactPathAliasesAndAmbiguousVersionsNeverGuessBasenames() throws {
        let root = URL(fileURLWithPath: "/library")
        var a = item("a", source: "/manual/guide.md")
        let b = item("b", source: "/manual/sub/目标.md")
        let wrong = item("wrong", source: "/elsewhere/目标.md")
        #expect(try MarkdownLinks.resolve(URL(string: "sub/目标.md")!, from: a, items: [a, b, wrong], root: root) == .item(id: b.id, fragment: nil))
        #expect(try MarkdownLinks.resolve(URL(string: "目标.md")!, from: a, items: [a, b, wrong], root: root) == .localFile(URL(fileURLWithPath: "/manual/目标.md"), fragment: nil))
        let duplicate = item("duplicate", source: "/manual/sub/目标.md")
        #expect(throws: (any Error).self) { try MarkdownLinks.resolve(URL(string: "sub/目标.md")!, from: a, items: [a, b, duplicate], root: root) }
        a.sourcePaths.append("/second/guide.md")
        let alternate = item("alternate", source: "/second/sub/目标.md")
        #expect(throws: (any Error).self) { try MarkdownLinks.resolve(URL(string: "sub/目标.md")!, from: a, items: [a, b, alternate], root: root) }
    }

    @Test func handbookRoutesAreScopedToLanguageAndKeepPunctuation() throws {
        let root = URL(fileURLWithPath: "/library")
        let a = item("index", source: "/handbook/日常操作手册.md")
        let en = item("index-en", source: "/handbook/en/日常操作手册.md")
        let b = item("b", source: "/handbook/menus/01-系统/M091-工单模板（当前不可用）.md")
        let ben = item("b-en", source: "/handbook/en/menus/01-系统/M091-工单模板（当前不可用）.md")
        let items = [a, en, b, ben]
        let url = URL(string: "index.html#doc-menus-01-系统-M091-工单模板-当前不可用-")!
        #expect(try MarkdownLinks.resolve(url, from: a, items: items, root: root) == .item(id: b.id, fragment: nil))
        #expect(try MarkdownLinks.resolve(url, from: en, items: items, root: root) == .item(id: ben.id, fragment: nil))
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.fragment! += "-1--业务用途"
        let section = components.url!
        #expect(try MarkdownLinks.resolve(section, from: en, items: items, root: root) == .item(id: ben.id, fragment: "1--业务用途"))
        let html = LibraryItem(id: "html", title: "index.html", kind: .document, relativePath: "index.html", text: "HTML",
                               extractionNote: nil, byteCount: 0, createdAt: .distantPast, updatedAt: .distantPast,
                               collectionID: nil, favorite: false, sourcePaths: ["/handbook/en/index.html"])
        #expect(try MarkdownLinks.resolve(url, from: en, items: items + [html], root: root) == .item(id: ben.id, fragment: nil))
        #expect(try MarkdownLinks.resolve(URL(string: "index.html")!, from: en, items: items + [html], root: root) == .item(id: html.id, fragment: nil))
    }

    @Test func localLinkBoundaryAndFragments() throws {
        let a = item("a", source: "/manual/guide.md")
        let root = URL(fileURLWithPath: "/library")
        for url in ["javascript:alert(1)", "data:text/html,hello", "smb://host/share", "file://host/etc/passwd", "https:/relative", "target.md?query=1", "file:///etc/a%00b", "file://user:pass@localhost/a", "file:relative.md", "guide.md#%FF"] {
            #expect(throws: (any Error).self) { try MarkdownLinks.resolve(URL(string: url)!, from: a, items: [a], root: root) }
        }
        #expect(try MarkdownLinks.resolve(URL(string: "#中文标题")!, from: a, items: [a], root: root) == .item(id: a.id, fragment: "中文标题"))
        #expect(try MarkdownLinks.resolve(URL(string: "#")!, from: a, items: [a], root: root) == .item(id: a.id, fragment: ""))
        #expect(try MarkdownLinks.resolve(URL(string: "../read%20me.pdf")!, from: a, items: [a], root: root) == .localFile(URL(fileURLWithPath: "/read me.pdf"), fragment: nil))
        #expect(try MarkdownLinks.resolve(URL(string: "https://example.com/#part")!, from: a, items: [a], root: root) == .web(URL(string: "https://example.com/#part")!))
    }

    @Test func restoreSourcesChecksContentAndMigrationPreservesExistingRows() async throws {
        let temp = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = temp.appendingPathComponent("a.md"), alias = temp.appendingPathComponent("alias.md"), wrong = temp.appendingPathComponent("wrong.md")
        try "original".write(to: source, atomically: true, encoding: .utf8)
        try "original".write(to: alias, atomically: true, encoding: .utf8)
        try "changed".write(to: wrong, atomically: true, encoding: .utf8)
        let root = temp.appendingPathComponent("Library")
        let repo = try LibraryRepository(root: root)
        let id = try #require(try await repo.importFiles([source]).importedIDs.first)
        let db = try Database(url: root.appendingPathComponent("library.sqlite"))
        try db.execute("DROP TABLE item_sources")
        try db.execute("PRAGMA user_version = 3")
        let before = try db.rows("SELECT * FROM items")
        let migrated = try LibraryRepository(root: root)
        #expect(try db.rows("SELECT * FROM items") == before)
        await #expect(throws: (any Error).self) { try await migrated.restoreSourceLocations(id: id, urls: [source, wrong]) }
        #expect(try await migrated.snapshot().items.first?.sourcePaths.isEmpty == true)
        try await migrated.restoreSourceLocations(id: id, urls: [source, alias])
        try await migrated.restoreSourceLocations(id: id, urls: [source, alias])
        #expect(try await migrated.snapshot().items.first?.sourcePaths.count == 2)
        #expect(try db.rows("SELECT * FROM items") == before)
    }

    @Test func sectionsKeepReferenceLinksTablesCodeAndUniqueUnicodeAnchors() throws {
        let source = """
        [前往][target]

        # 1. 中文**标题**

        | A | B |
        | - | - |
        | a | b |

        ## 重复

        - [x] 完成

        ## 重复-1

        ## 重复

        > ### 引用标题
        > 正文

        ```md
        # 这不是标题
        ```

        [target]: <业务%20说明.md#1-中文标题>
        """
        let parsed = try MarkdownStructure.parse(source)
        #expect(parsed.anchors["1-中文标题"] == 1)
        #expect(parsed.anchors["1--中文标题"] == 1) // Native/handbook spelling remains an alias.
        #expect(parsed.anchors["重复"] == 2)
        #expect(parsed.anchors["重复-1"] == 3)
        #expect(parsed.anchors["重复-2"] == 4)
        #expect(parsed.anchors["引用标题"] == 5)
        #expect(parsed.anchors["这不是标题"] == nil)
        let rendered = parsed.sections.map(\.markdown).joined()
        #expect(rendered.contains("%E4%B8%9A%E5%8A%A1%20%E8%AF%B4%E6%98%8E.md#1-%E4%B8%AD%E6%96%87%E6%A0%87%E9%A2%98"))
        #expect(rendered.contains("[x]"))
        #expect(rendered.contains("|"))
        #expect(rendered.contains("这不是标题"))
    }
}
