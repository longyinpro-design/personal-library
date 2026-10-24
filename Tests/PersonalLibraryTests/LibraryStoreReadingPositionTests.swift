import Foundation
import LibraryCore
import Testing
@testable import PersonalLibrary

@MainActor
struct LibraryStoreReadingPositionTests {
    private func fixture() async throws -> (URL, LibraryStore, String) {
        let root = testTemporaryDirectory.appendingPathComponent("store-reading-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("library")
        let repo = try LibraryRepository(root: library)
        let note = try await repo.saveNote(title: "长笔记", body: "# 一\n\n正文\n\n## 二", kind: .note, collectionID: nil)
        let store = LibraryStore(root: library)
        await store.load()
        await store.searchTask?.value
        return (root, store, note)
    }

    @Test func rememberedPositionSurvivesRelaunch() async throws {
        let (root, store, id) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        store.rememberReadingAnchor(.markdownSection(4), for: id)
        await store.flushReadingPositions()

        let relaunched = LibraryStore(root: root.appendingPathComponent("library"))
        await relaunched.load()
        await relaunched.searchTask?.value
        #expect(relaunched.readingAnchor(for: id) == .markdownSection(4))
    }

    @Test func plainTextChunksAreRememberedToo() async throws {
        let (root, store, id) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        store.rememberReadingAnchor(.bodyChunk(2), for: id)
        await store.flushReadingPositions()

        let relaunched = LibraryStore(root: root.appendingPathComponent("library"))
        await relaunched.load()
        await relaunched.searchTask?.value
        #expect(relaunched.readingAnchor(for: id) == .bodyChunk(2))
    }

    @Test func trashedItemKeepsItsPositionForWhenItComesBack() async throws {
        let (root, store, id) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        store.rememberReadingAnchor(.markdownSection(6), for: id)
        await store.flushReadingPositions()
        store.requestTrash([id])
        await store.confirmDelete([id])
        await store.restoreFromTrash([id])?.value
        await store.searchTask?.value
        #expect(store.readingAnchor(for: id) == .markdownSection(6))
    }
}
