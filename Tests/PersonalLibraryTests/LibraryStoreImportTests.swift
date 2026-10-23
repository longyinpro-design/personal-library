import Foundation
import Testing
import LibraryCore
@testable import PersonalLibrary

@MainActor
struct LibraryStoreImportTests {
    private func fixture() async throws -> (URL, LibraryStore, String, String, String, URL) {
        let root = testTemporaryDirectory.appendingPathComponent("store-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("library")
        let repo = try LibraryRepository(root: library)
        let alpha = try await repo.createCollection(name: "甲目录")
        let beta = try await repo.createCollection(name: "乙目录")
        _ = try await repo.saveNote(title: "旧选择", body: "甲目录内容", kind: .note, collectionID: alpha)
        _ = try await repo.saveNote(title: "另一个命中", body: "保留的内容", kind: .note, collectionID: beta)
        let target = try await repo.saveNote(title: "保留的选择", body: "保留的内容", kind: .note, collectionID: beta)
        let source = root.appendingPathComponent("import.txt")
        try "后台导入的新资料".write(to: source, atomically: true, encoding: .utf8)
        let store = LibraryStore(root: library)
        await store.load()
        await store.searchTask?.value
        return (root, store, alpha, beta, target, source)
    }

    @Test func completionPreservesNavigationSearchFilterAndSelectionMadeDuringImport() async throws {
        let (root, store, alpha, beta, target, source) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.navigate(.collection(alpha))
        await store.searchTask?.value
        let operation = try #require(store.importFiles([source]))
        #expect(store.isImporting)
        #expect(store.importFiles([source]) == nil)
        store.navigate(.collection(beta))
        store.query = "保留"
        store.kindFilter = .note
        store.selectedID = target
        await operation.value
        await store.searchTask?.value
        #expect(!store.isImporting && store.errorMessage == nil)
        #expect(store.scope == .collection(beta))
        #expect(store.query == "保留" && store.kindFilter == .note)
        #expect(store.selectedID == target && store.displayedItems.count == 2)
        #expect(store.snapshot.items.count == 4)
        #expect(try String(contentsOf: source, encoding: .utf8) == "后台导入的新资料")
    }

    @Test func completionAddsResultsWithoutReplacingCurrentSelection() async throws {
        let (root, store, _, _, target, source) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.selectedID = target
        let before = store.resultListID
        let operation = try #require(store.importFiles([source]))
        await operation.value
        await store.searchTask?.value
        #expect(store.scope == .all && store.query.isEmpty && store.kindFilter == nil)
        #expect(store.selectedID == target)
        #expect(store.displayedItems.count == 4 && store.resultListID != before)
        #expect(!store.isImporting)
    }

    @Test func emptyLibrarySelectsImportedResultWithoutExplicitNavigation() async throws {
        let root = testTemporaryDirectory.appendingPathComponent("empty-import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("first.md")
        try "# 第一份资料".write(to: source, atomically: true, encoding: .utf8)
        let store = LibraryStore(root: root.appendingPathComponent("library"))
        await store.load()
        await store.searchTask?.value
        let operation = try #require(store.importFiles([source]))
        await operation.value
        await store.searchTask?.value
        #expect(store.scope == .all && store.displayedItems.count == 1)
        #expect(store.selectedItem?.title == "first.md")
        #expect(!store.isImporting && store.errorMessage == nil)
    }
}
