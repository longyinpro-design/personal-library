import Foundation
import Testing
@testable import LibraryCore

struct SearchResultsTests {
    private func item(_ id: String, title: String, text: String) -> LibraryItem {
        LibraryItem(id: id, title: title, kind: .document, relativePath: nil, text: text,
                    extractionNote: nil, byteCount: 0, createdAt: .distantPast,
                    updatedAt: .distantPast, collectionID: nil, favorite: false)
    }

    @Test func matchesExistingUnicodeAndMultiTermSemantics() throws {
        let items = [
            item("1", title: "巴西项目", text: "现场验收 Energia elétrica café Straße"),
            item("2", title: "CEMIG.xlsx", text: ""),
            item("3", title: "Unicode", text: "cafe\u{301} ＡＢＣ İstanbul STRASSE 🧑🏽‍💻"),
            item("4", title: "Notes", text: "Greek Ελληνικά\n电表采集与跨页办理")
        ]
        for query in ["", " \n ", "巴西 验收", "巴西 香港", "energia ELETRICA", "CAFE", "strasse", "ＡＢＣ", "abc", "istanbul", "🧑🏽‍💻", "电表", "CEMIG", "跨页 办理", "missing"] {
            let result = try LibrarySearch.search(items, query: query)
            #expect(result.items.map(\.id) == items.filter { LibrarySearch.matches($0, query: query) }.map(\.id), "query: \(query)")
            #expect(Set(result.presentations.keys) == Set(result.items.map(\.id)))
            #expect(result.query == query)
        }
    }

    @Test func cachedSnippetsLocateBodyWhenFirstTermOnlyMatchesTitle() throws {
        let text = String(repeating: "前言", count: 250) + "现场验收内容" + String(repeating: "后记", count: 250)
        let result = try LibrarySearch.search([item("1", title: "巴西项目", text: text)], query: "巴西 验收")
        let presentation = try #require(result.presentations["1"])
        #expect(presentation.excerpt == LibrarySearch.excerpt(text, query: "巴西 验收"))
        #expect(presentation.matchingExcerpt == LibrarySearch.excerpt(text, query: "巴西 验收", limit: 330))
        #expect(presentation.excerpt.hasPrefix("…"))
        let titleOnly = try LibrarySearch.search([item("1", title: "巴西项目", text: text)], query: "巴西")
        #expect(titleOnly.presentations["1"]?.matchingExcerpt == nil)
    }

    @Test func cancelledSearchDoesNotReturnPartialResults() async throws {
        let values = [item("1", title: "材料", text: String(repeating: "电表采集", count: 100_000))]
        let worker = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try LibrarySearch.search(values, query: "电表")
        }
        worker.cancel()
        do { _ = try await worker.value; Issue.record("Cancelled search must not publish results") }
        catch is CancellationError {} catch { Issue.record(error) }
    }
}
