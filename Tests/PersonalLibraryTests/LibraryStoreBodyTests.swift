import Foundation
import Testing
@testable import LibraryCore
@testable import PersonalLibrary

@MainActor
struct LibraryStoreBodyTests {
    private func makeRepository(_ name: String) throws -> (LibraryRepository, URL) {
        let root = testTemporaryDirectory.appendingPathComponent("store-body-\(name)-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try LibraryRepository(root: root), root)
    }

    private func loadedStore(root: URL) async -> LibraryStore {
        let store = LibraryStore(root: root)
        await store.load()
        await store.searchTask?.value
        return store
    }

    @Test func repositorySearchLoadsMetadataThenBodyOnDemand() async throws {
        let (repo, root) = try makeRepository("search")
        defer { try? FileManager.default.removeItem(at: root) }
        let body = String(repeating: "现场验收记录。", count: 100)
        let id = try await repo.saveNote(title: "巴西项目", body: body, kind: .note)
        let store = await loadedStore(root: root)

        store.query = "巴西 验收"
        await store.searchTask?.value

        #expect(store.displayedItems.map(\.id) == [id])
        #expect(store.selectedItem?.text.isEmpty == true)
        #expect(store.selectedItem?.textLoaded == false)
        #expect(store.selectedItem?.preview.hasPrefix("现场验收") == true)

        await store.loadBody(id)
        #expect(store.selectedItem?.text == body)
        #expect(store.selectedItem?.textLoaded == true)
    }

    @Test func favoriteUpdatesSnapshotWithoutReloading() async throws {
        let (repo, root) = try makeRepository("favorite")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await repo.saveNote(title: "收藏测试", body: "正文", kind: .note)
        let store = await loadedStore(root: root)
        store.snapshot.collections = [LibraryCollection(id: "sentinel", name: "哨兵")]
        store.selectedID = id

        let task = store.setFavorite([id], value: true)
        await task?.value

        #expect(store.snapshot.items.first(where: { $0.id == id })?.favorite == true)
        #expect(store.snapshot.collections.map(\.id) == ["sentinel"])
        #expect(store.status == "已收藏")
    }

    @Test func organizeUpdatesSnapshotAndActivityWithoutReloading() async throws {
        let (repo, root) = try makeRepository("organize")
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = try await repo.createCollection(name: "项目")
        let id = try await repo.saveNote(title: "归类测试", body: "正文", kind: .note)
        let store = await loadedStore(root: root)
        let sentinel = LibraryActivity(id: "sentinel", message: "哨兵记录", date: .distantPast)
        store.snapshot.activities = [sentinel]
        store.selectedID = id

        let task = store.organize([id], into: collection)
        await task?.value

        #expect(store.snapshot.items.first(where: { $0.id == id })?.collectionID == collection)
        #expect(store.snapshot.activities.first?.message == "将「归类测试」归入「项目」")
        #expect(store.snapshot.activities.last?.id == "sentinel")
        #expect(store.status == "已归入「项目」")
    }

    @Test func editLoadsBodyBeforeOpeningDraft() async throws {
        let (repo, root) = try makeRepository("edit")
        defer { try? FileManager.default.removeItem(at: root) }
        let body = String(repeating: "长正文", count: 50)
        let id = try await repo.saveNote(title: "编辑测试", body: body, kind: .note)
        let store = await loadedStore(root: root)
        store.query = "编辑"
        await store.searchTask?.value
        let item = try #require(store.selectedItem)

        store.edit(item)
        for _ in 0..<100 where store.draft == nil {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.draft?.itemID == id)
        #expect(store.draft?.body == body)
    }
}
