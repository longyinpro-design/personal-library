import Foundation
import LibraryCore
import Testing
@testable import PersonalLibrary

@MainActor
struct LibraryStoreCollectionTests {
    private func fixture() async throws -> (URL, LibraryStore) {
        let root = testTemporaryDirectory.appendingPathComponent("store-collections-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("library")
        let repo = try LibraryRepository(root: library)
        _ = try await repo.saveNote(title: "笔记", body: "正文", kind: .note, collectionID: nil)
        let store = LibraryStore(root: library)
        await store.load()
        await store.searchTask?.value
        return (root, store)
    }

    @Test func rowsListParentsBeforeChildrenWithDepth() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.createCollection("2025")
        store.newCollectionParentID = nil
        guard let year = store.snapshot.collections.first(where: { $0.name == "2025" }) else {
            Issue.record("没有建出目录")
            return
        }
        store.beginNewCollection(in: year.id)
        try await store.createCollection("合同")

        let rows = store.collectionRows
        #expect(rows.map(\.name) == ["2025", "合同"])
        #expect(rows.map(\.depth) == [0, 1])
        #expect(store.collectionPath(rows[1].id) == "2025 › 合同")
        // Creating a child expands its parent so the new folder is visible.
        #expect(store.expandedCollections.contains(year.id))
    }

    @Test func renamingAFolderUpdatesItsPath() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.createCollection("草稿")
        guard let folder = store.snapshot.collections.first else {
            Issue.record("没有建出目录")
            return
        }
        await store.renameCollection(folder, to: "定稿")?.value
        await store.searchTask?.value
        #expect(store.collectionPath(folder.id) == "定稿")
    }

    @Test func deletingTheFolderInViewFallsBackToAllItems() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.createCollection("临时")
        guard let folder = store.snapshot.collections.first else {
            Issue.record("没有建出目录")
            return
        }
        #expect(store.scope == .collection(folder.id))
        await store.deleteCollection(folder)?.value
        await store.searchTask?.value
        #expect(store.scope == .all)
        #expect(store.snapshot.collections.isEmpty)
    }

    @Test func movingAFolderChangesItsPathAndExpandsTheTarget() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.createCollection("甲")
        guard let first = store.snapshot.collections.first else {
            Issue.record("没有建出目录")
            return
        }
        store.beginNewCollection(in: nil)
        try await store.createCollection("乙")
        guard let second = store.snapshot.collections.first(where: { $0.id != first.id }) else {
            Issue.record("没有建出第二个目录")
            return
        }
        await store.moveCollection(first, to: second.id)?.value
        await store.searchTask?.value
        #expect(store.collectionPath(first.id) == "乙 › 甲")
        #expect(store.expandedCollections.contains(second.id))
    }

    @Test func movingAFolderUnderItsOwnChildReportsInsteadOfLooping() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.createCollection("上")
        guard let parent = store.snapshot.collections.first else {
            Issue.record("没有建出目录")
            return
        }
        store.beginNewCollection(in: parent.id)
        try await store.createCollection("下")
        guard let child = store.snapshot.collections.first(where: { $0.id != parent.id }) else {
            Issue.record("没有建出子目录")
            return
        }
        await store.moveCollection(parent, to: child.id)?.value
        await store.searchTask?.value
        #expect(store.collectionPath(parent.id) == "上")
        #expect(store.status.contains("子目录"))
    }
}
