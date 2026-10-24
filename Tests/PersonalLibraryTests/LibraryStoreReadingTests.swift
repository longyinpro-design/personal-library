import Foundation
import Testing
@testable import LibraryCore
@testable import PersonalLibrary

@MainActor
struct LibraryStoreReadingTests {
    private func makeRepository(_ name: String) throws -> (LibraryRepository, URL) {
        let root = testTemporaryDirectory.appendingPathComponent("store-reading-\(name)-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try LibraryRepository(root: root), root)
    }

    private func loadedStore(root: URL) async -> LibraryStore {
        let store = LibraryStore(root: root)
        await store.load()
        await store.searchTask?.value
        return store
    }

    @Test func anchorsAreRememberedPerItem() async throws {
        let (repo, root) = try makeRepository("anchors")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await repo.saveNote(title: "甲", body: "正文", kind: .note)
        let second = try await repo.saveNote(title: "乙", body: "正文", kind: .thought)
        let store = await loadedStore(root: root)

        store.rememberReadingAnchor(.bodyChunk(7), for: first)
        store.rememberReadingAnchor(.markdownSection(3), for: second)

        #expect(store.readingAnchor(for: first) == .bodyChunk(7))
        #expect(store.readingAnchor(for: second) == .markdownSection(3))
        #expect(store.readingAnchor(for: "unknown") == nil)
    }

    @Test func reloadDropsAnchorsForDeletedItemsAndKeepsTheRest() async throws {
        let (repo, root) = try makeRepository("prune")
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = try await repo.saveNote(title: "保留", body: "正文", kind: .note)
        let removed = try await repo.saveNote(title: "删除", body: "正文", kind: .note)
        let store = await loadedStore(root: root)
        store.rememberReadingAnchor(.bodyChunk(2), for: kept)
        store.rememberReadingAnchor(.bodyChunk(5), for: removed)

        store.requestDelete([removed])
        await store.confirmDelete()

        #expect(store.readingAnchor(for: removed) == nil)
        #expect(store.readingAnchor(for: kept) == .bodyChunk(2))
    }

    @Test func switchingItemsKeepsTheLastAnchorOfThePreviousItem() async throws {
        let (repo, root) = try makeRepository("switch")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await repo.saveNote(title: "甲", body: "正文", kind: .note)
        let second = try await repo.saveNote(title: "乙", body: "正文", kind: .note)
        let store = await loadedStore(root: root)

        store.selectedID = first
        store.rememberReadingAnchor(.bodyChunk(4), for: first)
        store.selectedID = second
        #expect(store.readingAnchor(for: first) == .bodyChunk(4))
        #expect(store.readingAnchor(for: second) == nil)
    }
}

@MainActor
struct MarkdownDocumentOutlineTests {
    @Test func publishedOutlineMatchesTheParsedSections() async throws {
        let source = """
        # 总览

        正文。

        ## 数据来源

        更多正文。

        ### 计量协议

        结尾。
        """
        let document = MarkdownDocument()
        await document.load(source)

        #expect(document.headings.map(\.title) == ["总览", "数据来源", "计量协议"])
        #expect(document.headings.map(\.level) == [1, 2, 3])
        #expect(document.sectionSources.count == document.sections.count)
        #expect(document.anchors["计量协议"] == document.headings[2].section)
        for heading in document.headings {
            #expect(document.sectionSources.indices.contains(heading.section))
            #expect(document.sectionSources[heading.section].contains(heading.title))
        }
    }

    @Test func reloadingTheSameSourceKeepsTheParsedOutline() async throws {
        let document = MarkdownDocument()
        await document.load("# 甲\n\n正文。")
        let headings = document.headings
        let sections = document.sections.count

        await document.load("# 甲\n\n正文。")

        #expect(document.headings == headings)
        #expect(document.sections.count == sections)
    }
}
