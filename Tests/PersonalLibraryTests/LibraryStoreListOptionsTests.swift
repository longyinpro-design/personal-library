import Foundation
import LibraryCore
import Testing
@testable import PersonalLibrary

@MainActor
struct LibraryStoreListOptionsTests {
    private func fixture() async throws -> (URL, LibraryStore, [String]) {
        let root = testTemporaryDirectory.appendingPathComponent("store-options-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("library")
        let repo = try LibraryRepository(root: library)
        let folder = try await repo.createCollection(name: "目录甲")
        let beta = try await repo.saveNote(title: "Beta", body: String(repeating: "b", count: 400), kind: .note, collectionID: nil)
        let alpha = try await repo.saveNote(title: "Alpha", body: "短", kind: .note, collectionID: nil)
        let gamma = try await repo.saveNote(title: "Gamma", body: "看 [链接](https://example.com)", kind: .note, collectionID: folder)
        let store = LibraryStore(root: library)
        await store.load()
        await store.searchTask?.value
        return (root, store, [alpha, beta, gamma])
    }

    @Test func sortingReordersTheItemsAlreadyInTheList() async throws {
        let (root, store, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.displayedItems.count == 3)
        let byUpdate = store.resultListID

        store.listOptions.sortField = .title
        store.listOptions.ascending = true
        await store.searchTask?.value

        #expect(store.displayedItems.map(\.title) == ["Alpha", "Beta", "Gamma"])
        #expect(store.resultListID != byUpdate)

        store.listOptions.sortField = .size
        store.listOptions.ascending = false
        await store.searchTask?.value
        #expect(store.displayedItems.map(\.title).first == "Beta")
    }

    @Test func filtersUseTheMetadataTheSnapshotAlreadyLoaded() async throws {
        let (root, store, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        store.listOptions.onlyWithLinks = true
        await store.searchTask?.value
        #expect(store.displayedItems.map(\.title) == ["Gamma"])

        store.listOptions.onlyWithLinks = false
        store.listOptions.maxBytes = 20
        await store.searchTask?.value
        #expect(store.displayedItems.map(\.title) == ["Alpha"])

        store.listOptions.minBytes = nil
        store.listOptions.maxBytes = nil
        store.listOptions.onlyWithImages = true
        await store.searchTask?.value
        #expect(store.displayedItems.isEmpty)
    }

    @Test func optionsSurviveSwitchingFolders() async throws {
        let (root, store, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        store.listOptions.sortField = .title
        store.listOptions.ascending = true
        store.listOptions.onlyWithLinks = true
        store.navigate(.all)
        await store.searchTask?.value
        #expect(store.displayedItems.map(\.title) == ["Gamma"])

        store.listOptions.onlyWithLinks = false
        store.navigate(.inbox)
        await store.searchTask?.value
        #expect(store.displayedItems.map(\.title) == ["Alpha", "Beta"])
        #expect(store.listOptions.sortField == .title)
        #expect(store.listOptions.ascending)
        #expect(!store.listOptions.onlyWithLinks)
    }

    @Test func anActiveQueryKeepsRelevanceUntilAnotherSortIsPicked() async throws {
        let (root, store, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        store.query = "短"
        await store.searchTask?.value
        #expect(store.displayedItems.map(\.title) == ["Alpha"])

        store.query = "a" // matches every title, so the relevance order is the search's own
        await store.searchTask?.value
        #expect(store.displayedItems.count == 3)

        store.listOptions.sortField = .title
        store.listOptions.ascending = true
        await store.searchTask?.value
        #expect(store.displayedItems.map(\.title) == ["Alpha", "Beta", "Gamma"])
    }
}
