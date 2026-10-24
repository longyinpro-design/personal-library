import Foundation
@testable import LibraryCore
@testable import PersonalLibrary
import Testing

@Suite(.serialized)
final class LibraryStoreTrashTests {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("Library") }

    init() throws {
        temporary = testTemporaryDirectory.appendingPathComponent("store-trash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: temporary) }

    /// `load()` is one-shot, so tests seed the repository before building the store.
    @MainActor
    private func loadedStore() async -> LibraryStore {
        let store = LibraryStore(root: root)
        await store.load()
        await store.searchTask?.value
        return store
    }

    @Test @MainActor func trashScopeListsTrashedItemsAndUndoRestoresThem() async throws {
        let repo = try LibraryRepository(root: root)
        let kept = try await repo.saveNote(title: "保留", body: "正文", kind: .note)
        let removed = try await repo.saveNote(title: "回收", body: "正文", kind: .note)
        let store = await loadedStore()

        store.selection = [removed]
        store.requestTrashSelection()
        await store.confirmDelete()

        #expect(store.snapshot.items.map(\.id) == [kept])
        #expect(store.trashedCount == 1)
        #expect(store.canUndoTrash)

        store.navigate(.trash)
        await store.searchTask?.value
        #expect(store.displayedItems.map(\.id) == [removed])

        await store.undoTrash()?.value
        await store.searchTask?.value
        #expect(!store.canUndoTrash)
        #expect(store.trashedCount == 0)
        #expect(store.displayedItems.isEmpty)
        #expect(store.snapshot.items.count == 2)
    }

    @Test @MainActor func trashScopeFiltersByQueryWithoutHittingTheDatabase() async throws {
        let repo = try LibraryRepository(root: root)
        let first = try await repo.saveNote(title: "苹果 笔记", body: "正文", kind: .note)
        let second = try await repo.saveNote(title: "香蕉 笔记", body: "正文", kind: .note)
        _ = try await repo.moveToTrash(ids: [first, second])
        let store = await loadedStore()

        store.navigate(.trash)
        await store.searchTask?.value
        #expect(store.displayedItems.count == 2)

        store.query = "苹果"
        await store.searchTask?.value
        #expect(store.displayedItems.map(\.id) == [first])
    }

    @Test @MainActor func permanentDeletionFromTrashNeedsItsOwnConfirmation() async throws {
        let repo = try LibraryRepository(root: root)
        let id = try await repo.saveNote(title: "彻底删除", body: "正文", kind: .note)
        _ = try await repo.moveToTrash(ids: [id])
        let store = await loadedStore()
        #expect(store.trashedCount == 1)

        store.requestPermanentDelete([id])
        #expect(store.pendingDeletionIsPermanent)
        #expect(store.pendingDeletion == [id])
        store.cancelDelete()
        #expect(store.pendingDeletion.isEmpty)
        #expect(!store.pendingDeletionIsPermanent)
        #expect(store.trashedCount == 1)
    }

    @Test @MainActor func emptyTrashAsksBeforeDestroyingAnything() async throws {
        let repo = try LibraryRepository(root: root)
        let id = try await repo.saveNote(title: "清空", body: "正文", kind: .note)
        _ = try await repo.moveToTrash(ids: [id])
        let store = await loadedStore()

        store.requestEmptyTrash()
        #expect(store.confirmEmptyTrash)
        #expect(store.trashedCount == 1)

        await store.emptyTrash()?.value
        #expect(store.trashedCount == 0)
        #expect(store.snapshot.items.isEmpty)
    }
}
