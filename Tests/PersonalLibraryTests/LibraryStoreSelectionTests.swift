import Foundation
import Testing
@testable import LibraryCore
@testable import PersonalLibrary

@MainActor
struct LibraryStoreSelectionTests {
    private func item(_ id: String, text: String, kind: ItemKind = .document,
                      collection: String? = nil, favorite: Bool = false) -> LibraryItem {
        LibraryItem(id: id, title: id, kind: kind, relativePath: nil, text: text,
                    extractionNote: nil, byteCount: 0, createdAt: .distantPast,
                    updatedAt: .distantPast, collectionID: collection, favorite: favorite)
    }

    private func snapshot(_ items: [LibraryItem]) -> LibrarySnapshot {
        var result = LibrarySnapshot(); result.items = items; return result
    }

    @Test func multipleSelectionHasNoSingleSelectedItem() async {
        let store = LibraryStore()
        store.snapshot = snapshot([item("1", text: "one"), item("2", text: "two"), item("3", text: "three")])
        await store.searchTask?.value

        store.selection = ["1", "2"]

        #expect(store.selectedID == nil)
        #expect(store.selectedItem == nil)
        #expect(store.items(for: ["2", "3"]).map(\.id) == ["2", "3"])
        store.selectedID = "3"
        #expect(store.selection == ["3"])
        #expect(store.selectedItem?.id == "3")
    }

    @Test func searchKeepsOnlyVisibleSelection() async {
        let store = LibraryStore()
        store.snapshot = snapshot([item("1", text: "one"), item("2", text: "two")])
        await store.searchTask?.value
        store.selection = ["1", "2"]

        store.query = "one"
        await store.searchTask?.value

        #expect(store.displayedItems.map(\.id) == ["1"])
        #expect(store.selection == ["1"])
    }

    @Test func confirmingDeletionClearsSelectionAndRows() async throws {
        let root = testTemporaryDirectory.appendingPathComponent("store-deletion-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LibraryRepository(root: root)
        let first = try await repo.saveNote(title: "一", body: "正文", kind: .note)
        let second = try await repo.saveNote(title: "二", body: "正文", kind: .note)
        let store = LibraryStore(root: root)
        await store.load()
        await store.searchTask?.value
        store.selection = [first, second]

        store.requestTrashSelection()
        #expect(store.pendingDeletion == [first, second])
        #expect(!store.pendingDeletionIsPermanent)
        await store.confirmDelete()

        #expect(store.snapshot.items.isEmpty)
        #expect(store.snapshot.trashed.count == 2)
        #expect(store.selection.isEmpty)
        #expect(!store.isDeleting)
        #expect(store.status == "已将 2 项移到回收站，\(LibraryRetention.trashDays) 天内可恢复")
    }

    @Test func batchFavoriteUpdatesAllRows() async throws {
        let root = testTemporaryDirectory.appendingPathComponent("store-favorite-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LibraryRepository(root: root)
        let first = try await repo.saveNote(title: "一", body: "正文", kind: .note)
        let second = try await repo.saveNote(title: "二", body: "正文", kind: .note)
        let store = LibraryStore(root: root)
        await store.load()
        await store.searchTask?.value

        let task = store.setFavorite([first, second], value: true)
        await task?.value

        #expect(store.snapshot.items.filter { !$0.favorite }.isEmpty)
        #expect(store.status == "已收藏 2 项")
    }
}
