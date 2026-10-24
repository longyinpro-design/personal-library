import Foundation
import LibraryCore
import Testing
@testable import PersonalLibrary

@MainActor
struct LibraryStoreTagTests {
    private func fixture(_ notes: [(String, String)]) async throws -> (URL, URL, LibraryStore) {
        let root = testTemporaryDirectory.appendingPathComponent("store-tags-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("library")
        let repo = try LibraryRepository(root: library)
        for (title, body) in notes {
            _ = try await repo.saveNote(title: title, body: body, kind: .note, collectionID: nil)
        }
        let store = LibraryStore(root: library)
        await store.load()
        await store.searchTask?.value
        return (root, library, store)
    }

    private func ids(in store: LibraryStore, titles: [String]) -> [String] {
        titles.compactMap { title in store.snapshot.items.first { $0.title == title }?.id }
    }

    @Test func clickingATagListsExactlyThatTagsItems() async throws {
        let (root, _, store) = try await fixture([("甲", "正文"), ("乙", "正文"), ("丙", "正文")])
        defer { try? FileManager.default.removeItem(at: root) }
        let tagged = ids(in: store, titles: ["甲", "丙"])
        await store.applyTags(["法务"], to: tagged)?.value
        await store.searchTask?.value

        store.navigate(.tag("法务"))
        await store.searchTask?.value
        #expect(Set(store.displayedItems.map(\.title)) == ["甲", "丙"])
        #expect(store.scopeTitle == "#法务")

        // The typed form agrees with the clicked one.
        store.query = "tag:法务"
        await store.searchTask?.value
        #expect(Set(store.displayedItems.map(\.title)) == ["甲", "丙"])
    }

    @Test func batchEditingAppliesOneTagListToTheWholeSelection() async throws {
        let (root, _, store) = try await fixture([("甲", "正文"), ("乙", "正文"), ("丙", "正文")])
        defer { try? FileManager.default.removeItem(at: root) }
        let firstTwo = Set(ids(in: store, titles: ["甲", "乙"]))

        store.beginTagEditing(ids: firstTwo)
        let request = try #require(store.tagEditorRequest)
        #expect(Set(store.tagEditorItems.map(\.title)) == ["甲", "乙"])

        await store.applyTags(["合同", "归档"], to: request.itemIDs)?.value
        #expect(store.tagEditorRequest == nil)
        let snapshot = store.snapshot
        #expect(snapshot.items.first { $0.title == "甲" }?.tags == ["合同", "归档"])
        #expect(snapshot.items.first { $0.title == "乙" }?.tags == ["合同", "归档"])
        #expect(snapshot.items.first { $0.title == "丙" }?.tags == [])
        #expect(snapshot.tags.first { $0.name == "合同" }?.count == 2)
    }

    @Test func deletingTheOpenTagsTagFallsBackToEverythingAndKeepsItems() async throws {
        let (root, _, store) = try await fixture([("甲", "正文")])
        defer { try? FileManager.default.removeItem(at: root) }
        await store.applyTags(["临时"], to: ids(in: store, titles: ["甲"]))?.value
        store.navigate(.tag("临时"))
        let tag = try #require(store.snapshot.tags.first)

        await store.deleteTag(tag)?.value
        #expect(store.scope == .all)
        #expect(store.snapshot.items.count == 1)
        #expect(store.snapshot.tags.isEmpty)
    }
}
