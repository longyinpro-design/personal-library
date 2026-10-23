import Foundation
import Testing
@testable import LibraryCore
@testable import PersonalLibrary

@MainActor
struct LibraryStoreSearchTests {
    private func item(_ id: String, text: String, kind: ItemKind = .document,
                      collection: String? = nil, favorite: Bool = false, age: TimeInterval = 0,
                      relativePath: String? = nil) -> LibraryItem {
        LibraryItem(id: id, title: id, kind: kind, relativePath: relativePath, text: text,
                    extractionNote: nil, byteCount: 0,
                    createdAt: Date(timeIntervalSince1970: age), updatedAt: .distantPast,
                    collectionID: collection, favorite: favorite)
    }

    private func snapshot(_ items: [LibraryItem]) -> LibrarySnapshot {
        var result = LibrarySnapshot(); result.items = items; return result
    }

    @Test func latestQueryScopeFilterAndSnapshotOwnTheResult() async {
        let store = LibraryStore()
        store.snapshot = snapshot([item("old", text: "电表", collection: "A")])
        store.query = "电表"
        let obsolete = store.searchTask
        store.query = "不存在"
        store.navigate(.collection("B"))
        store.kindFilter = .note
        store.snapshot = snapshot([item("new", text: "电表", kind: .note, collection: "B"),
                                   item("wrong-kind", text: "电表", collection: "B"),
                                   item("wrong-scope", text: "电表", kind: .note, collection: "A")])
        store.query = "电表"
        await store.searchTask?.value
        await obsolete?.value
        #expect(store.displayedItems.map(\.id) == ["new"])
        #expect(store.searchResults.query == "电表")
        #expect(store.selectedID == "new")
        #expect(!store.isSearching)
    }

    @Test func selectionMadeDuringSearchIsPreservedWhenStillVisible() async {
        let store = LibraryStore()
        store.snapshot = snapshot([item("1", text: "巴西验收"), item("2", text: "巴西部署")])
        await store.searchTask?.value
        store.query = "巴西"
        store.selectedID = "2"
        await store.searchTask?.value
        #expect(store.selectedID == "2")
        store.query = "验收"
        await store.searchTask?.value
        #expect(store.selectedID == "1")
        store.query = "不存在"
        await store.searchTask?.value
        #expect(store.selectedID == nil)
        #expect(store.displayedItems.isEmpty)
        store.query = ""
        await store.searchTask?.value
        #expect(store.displayedItems.count == 2)
        #expect(store.searchResults.query.isEmpty)
    }

    @Test func recentLimitAppliesBeforeQueryAndNavigationClearsType() async {
        let store = LibraryStore()
        store.snapshot = snapshot((0..<60).map { item("\($0)", text: $0 < 10 ? "needle" : "normal", age: Double($0)) })
        store.navigate(.recent)
        store.query = "needle"
        await store.searchTask?.value
        #expect(store.displayedItems.isEmpty)
        store.kindFilter = .note
        store.navigate(.all)
        await store.searchTask?.value
        #expect(store.kindFilter == nil)
        #expect(store.displayedItems.count == 10)
        store.navigate(.history)
        await store.searchTask?.value
        #expect(store.displayedItems.isEmpty)
        store.query = "normal"
        await store.searchTask?.value
        #expect(store.scope == .all)
        #expect(store.displayedItems.count == 50)
    }

    @Test func refreshUpdatesFavoriteMembershipWithUnchangedQuery() async {
        let store = LibraryStore()
        store.snapshot = snapshot([item("1", text: "电表", favorite: true)])
        store.navigate(.favorites)
        store.query = "电表"
        await store.searchTask?.value
        #expect(store.displayedItems.count == 1)
        store.snapshot = snapshot([item("1", text: "已更新的正文", favorite: false)])
        await store.searchTask?.value
        #expect(store.displayedItems.isEmpty)
        store.navigate(.all)
        store.query = "已更新"
        await store.searchTask?.value
        #expect(store.searchResults.presentations["1"]?.matchingExcerpt?.contains("已更新") == true)
    }

    @Test func linkedNavigationWinsObsoleteSearchAndBackRestoresFilters() async throws {
        let store = LibraryStore()
        var a = item("a", text: "菜单入口", collection: "A")
        var b = item("b", text: "# 目标标题", collection: "B")
        a.sourcePaths = ["/manual/a.md"]; b.sourcePaths = ["/manual/b.md"]
        a = LibraryItem(id: a.id, title: a.title, kind: .document, relativePath: "a.md", text: a.text,
                        extractionNote: nil, byteCount: 0, createdAt: .distantPast, updatedAt: .distantPast,
                        collectionID: "A", favorite: false, sourcePaths: a.sourcePaths)
        b = LibraryItem(id: b.id, title: b.title, kind: .document, relativePath: "b.md", text: b.text,
                        extractionNote: nil, byteCount: 0, createdAt: .distantPast, updatedAt: .distantPast,
                        collectionID: "B", favorite: false, sourcePaths: b.sourcePaths)
        store.snapshot = snapshot([a, b])
        store.navigate(.collection("A")); store.kindFilter = .document; store.query = "入口"
        await store.searchTask?.value
        #expect(store.selectedID == "a")
        store.query = "菜单入口"
        let obsolete = store.searchTask
        store.followMarkdownLink(URL(string: "b.md#目标标题")!, from: a)
        await store.searchTask?.value; await obsolete?.value
        #expect(store.selectedID == "b")
        #expect(store.scope == .collection("B") && store.query.isEmpty && store.kindFilter == nil)
        #expect(store.readingRequest?.fragment == "目标标题")
        store.goBack(); await store.searchTask?.value
        #expect(store.selectedID == "a")
        #expect(store.scope == .collection("A") && store.query == "菜单入口" && store.kindFilter == .document)
        store.goForward(); await store.searchTask?.value
        #expect(store.selectedID == "b")
        #expect(store.readingRequest?.fragment == "目标标题")
        store.followMarkdownLink(URL(string: "#")!, from: b)
        #expect(store.readingRequest?.fragment == "")
        store.goBack(); await store.searchTask?.value
        #expect(store.readingRequest?.fragment == "目标标题")
    }

    @Test func linkedNavigationKeepsSettledListAndDoesNotRestartSearch() async throws {
        let store = LibraryStore()
        var a = item("a.md", text: "共享目录入口", collection: "manual")
        var b = item("b.md", text: "共享目标", collection: "manual")
        a.sourcePaths = ["/manual/a.md"]; b.sourcePaths = ["/manual/b.md"]
        store.snapshot = snapshot([a, b, item("outside", text: "其他资料", collection: "other")])
        store.navigate(.collection("manual")); store.kindFilter = .document; store.query = "共享"
        await store.searchTask?.value
        store.selectedID = a.id
        let before = store.displayedItems.map(\.id)
        store.followMarkdownLink(URL(string: "b.md")!, from: a)
        #expect(store.scope == .collection("manual"))
        #expect(store.query == "共享" && store.kindFilter == .document)
        #expect(!store.isSearching)
        #expect(store.displayedItems.map(\.id) == before)
        #expect(store.selectedID == b.id)
        store.goBack()
        #expect(!store.isSearching && store.selectedID == a.id)
        store.goForward()
        #expect(!store.isSearching && store.selectedID == b.id)
    }

    @Test func pendingSearchCannotEvictLinkedTargetOrSamePageAnchor() async throws {
        let store = LibraryStore()
        var a = item("a.md", text: "入口", collection: "manual", relativePath: "a.md")
        var b = item("b.md", text: "# 目标", collection: "manual", relativePath: "b.md")
        a.sourcePaths = ["/manual/a.md"]; b.sourcePaths = ["/manual/b.md"]
        store.snapshot = snapshot([a, b]); store.navigate(.collection("manual"))
        await store.searchTask?.value
        store.selectedID = a.id
        store.query = "完全不匹配"
        let obsolete = store.searchTask
        store.followMarkdownLink(URL(string: "b.md#目标")!, from: a)
        await store.searchTask?.value; await obsolete?.value
        #expect(store.scope == .collection("manual") && store.query.isEmpty)
        #expect(store.selectedID == b.id && store.readingRequest?.fragment == "目标")
        store.query = "再次排除当前资料"
        let stale = store.searchTask
        store.followMarkdownLink(URL(string: "#目标")!, from: b)
        await store.searchTask?.value; await stale?.value
        #expect(store.scope == .collection("manual") && store.query.isEmpty)
        #expect(store.selectedID == b.id && store.readingRequest?.fragment == "目标")
    }

    @Test func resultReplacementPreservesSelectionAndContentOnlyRefreshKeepsList() async {
        let store = LibraryStore()
        let a = item("a", text: "共同内容", collection: "manual")
        let b = item("b", text: "共同内容", collection: "other")
        store.snapshot = snapshot([a, b]); store.navigate(.collection("manual"))
        await store.searchTask?.value
        let directoryList = store.resultListID
        store.selectedID = a.id
        store.navigate(.all)
        #expect(store.resultListID == directoryList) // A pending request must not replace the old results.
        await store.searchTask?.value
        let allList = store.resultListID
        #expect(allList != directoryList && store.selectedID == a.id)
        store.query = "共同"
        await store.searchTask?.value
        #expect(store.resultListID == allList && store.selectedID == a.id)
        var refreshed = a; refreshed.favorite = true
        store.snapshot = snapshot([refreshed, b])
        await store.searchTask?.value
        #expect(store.resultListID == allList && store.displayedItems.first?.favorite == true)
        store.snapshot = snapshot([b, refreshed])
        await store.searchTask?.value
        #expect(store.resultListID != allList && store.selectedID == a.id)
    }

    @Test func hiddenUnfiledTargetOpensInboxAndLatestNavigationWins() async throws {
        let store = LibraryStore()
        var a = item("a.md", text: "入口", collection: "manual")
        var b = item("b.md", text: "目标")
        var c = item("c.md", text: "下一份", collection: "other")
        a.sourcePaths = ["/manual/a.md"]; b.sourcePaths = ["/manual/b.md"]; c.sourcePaths = ["/manual/c.md"]
        store.snapshot = snapshot([a, b, c]); store.navigate(.collection("manual"))
        await store.searchTask?.value
        store.followMarkdownLink(URL(string: "b.md")!, from: a)
        let firstNavigation = store.searchTask
        #expect(store.scope == .inbox)
        store.followMarkdownLink(URL(string: "c.md")!, from: b)
        await store.searchTask?.value; await firstNavigation?.value
        #expect(store.scope == .collection("other") && store.selectedID == c.id)
        store.goBack(); await store.searchTask?.value
        #expect(store.scope == .inbox && store.selectedID == b.id)
    }
}
