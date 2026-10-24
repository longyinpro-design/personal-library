import Foundation
import Testing
@testable import LibraryCore

@Suite
final class ListOptionsTests {
    private func item(_ id: String, title: String, created: TimeInterval = 0, updated: TimeInterval = 0,
                      bytes: Int64 = 0, body: Bool = true, images: Bool = false, links: Bool = false) -> LibraryItem {
        var value = LibraryItem(id: id, title: title, kind: .note, relativePath: nil, text: "",
                                extractionNote: nil, byteCount: bytes,
                                createdAt: Date(timeIntervalSince1970: created),
                                updatedAt: Date(timeIntervalSince1970: updated),
                                collectionID: nil, favorite: false)
        value.hasBody = body
        value.hasLinks = links
        if images { value.imageAttachments = ["图": URL(fileURLWithPath: "/tmp/a.png")] }
        return value
    }

    @Test func eachFieldSortsInBothDirections() {
        let items = [item("b", title: "2. 草稿", created: 20, updated: 5, bytes: 300),
                     item("a", title: "10. 定稿", created: 10, updated: 9, bytes: 100),
                     item("c", title: "1. 初稿", created: 30, updated: 1, bytes: 200)]

        var options = LibraryListOptions()
        #expect(options.sorted(items).map(\.id) == ["a", "b", "c"]) // updated descending
        options.ascending = true
        #expect(options.sorted(items).map(\.id) == ["c", "b", "a"])

        options.sortField = .created
        options.ascending = false
        #expect(options.sorted(items).map(\.id) == ["c", "b", "a"])

        options.sortField = .size
        options.ascending = true
        #expect(options.sorted(items).map(\.id) == ["a", "c", "b"])

        // Natural order: "1. 初稿" first, even though "10." sorts before "2." as text.
        options.sortField = .title
        options.ascending = false
        #expect(options.sorted(items).map(\.id) == ["a", "b", "c"])
        options.ascending = true
        #expect(options.sorted(items).map(\.id) == ["c", "b", "a"])
    }

    @Test func equalValuesFallBackToTheIDSoRunsStayStable() {
        let items = [item("b", title: "同名"), item("a", title: "同名"), item("c", title: "同名")]
        var options = LibraryListOptions()
        #expect(options.sorted(items).map(\.id) == ["c", "b", "a"])
        options.ascending = true
        #expect(options.sorted(items).map(\.id) == ["a", "b", "c"])
    }

    @Test func filtersCoverDateSizeBodyImagesAndLinks() {
        let items = [item("old", title: "旧", created: 10, bytes: 50),
                     item("empty", title: "空正文", created: 20, bytes: 5_000, body: false),
                     item("rich", title: "有图有链接", created: 30, bytes: 900, images: true, links: true)]

        var options = LibraryListOptions()
        #expect(items.allSatisfy(options.matches))
        #expect(!options.hasFilters && options.filterCount == 0)

        options.startDate = Date(timeIntervalSince1970: 15)
        #expect(items.filter(options.matches).map(\.id) == ["empty", "rich"])
        #expect(options.filterCount == 1)

        options = LibraryListOptions()
        options.endDate = Date(timeIntervalSince1970: 25)
        #expect(items.filter(options.matches).map(\.id) == ["old", "empty"])

        options = LibraryListOptions()
        options.minBytes = 100
        options.maxBytes = 1_000
        #expect(items.filter(options.matches).map(\.id) == ["rich"])

        options = LibraryListOptions()
        options.onlyWithBody = true
        #expect(items.filter(options.matches).map(\.id) == ["old", "rich"])

        options = LibraryListOptions()
        options.onlyWithImages = true
        #expect(items.filter(options.matches).map(\.id) == ["rich"])

        options = LibraryListOptions()
        options.onlyWithLinks = true
        #expect(items.filter(options.matches).map(\.id) == ["rich"])
        #expect(options.filterCount == 1)
    }

    @Test func filtersAndSortingCompose() {
        let items = [item("a", title: "Beta", updated: 1, links: true),
                     item("b", title: "Alpha", updated: 2),
                     item("c", title: "Gamma", updated: 3, links: true)]
        var options = LibraryListOptions()
        options.onlyWithLinks = true
        options.sortField = .title
        options.ascending = true
        let visible = items.filter(options.matches)
        #expect(options.sorted(visible).map(\.id) == ["a", "c"]) // Beta < Gamma
    }
}
