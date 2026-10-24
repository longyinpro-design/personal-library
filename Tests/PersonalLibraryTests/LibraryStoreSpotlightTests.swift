import Foundation
import LibraryCore
import Testing
@testable import PersonalLibrary

/// Records what would have been sent to Spotlight, so tests never touch XPC.
private final class RecordingSpotlight: SpotlightSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storedIndexed: [SpotlightDocument] = []
    private var storedRemoved: [String] = []
    private var storedClears = 0

    func index(_ documents: [SpotlightDocument]) async {
        lock.lock(); storedIndexed += documents; lock.unlock()
    }

    func remove(identifiers: [String]) async {
        lock.lock(); storedRemoved += identifiers; lock.unlock()
    }

    func removeAll() async {
        lock.lock(); storedClears += 1; storedIndexed = []; lock.unlock()
    }

    var indexed: [SpotlightDocument] {
        lock.lock(); defer { lock.unlock() }; return storedIndexed
    }

    var removed: [String] {
        lock.lock(); defer { lock.unlock() }; return storedRemoved
    }

    var clears: Int {
        lock.lock(); defer { lock.unlock() }; return storedClears
    }
}

@MainActor
struct LibraryStoreSpotlightTests {
    private func fixture(_ notes: [(String, String)]) async throws -> (URL, LibraryStore, RecordingSpotlight) {
        let root = testTemporaryDirectory.appendingPathComponent("store-spotlight-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("library")
        let repository = try LibraryRepository(root: library)
        for (title, body) in notes {
            _ = try await repository.saveNote(title: title, body: body, kind: .note, collectionID: nil)
        }
        let store = LibraryStore(root: library)
        let sink = RecordingSpotlight()
        store.spotlightSink = sink
        store.spotlightEnabled = true
        await store.load()
        await store.searchTask?.value
        return (root, store, sink)
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test func loadingReportsTitlesAndTagsButNotBodies() async throws {
        let (root, store, sink) = try await fixture([("架构笔记", String(repeating: "正文", count: 200))])
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try #require(store.snapshot.items.first?.id)
        await store.applyTags(["架构"], to: [id])?.value
        await waitUntil { sink.indexed.contains { $0.id == id && !$0.keywords.isEmpty } }

        let document = try #require(sink.indexed.last { $0.id == id })
        #expect(document.title == "架构笔记")
        #expect(document.keywords == ["架构"])
        #expect(document.summary.count <= 240)
    }

    @Test func trashingAnItemRemovesItsIdentifierFromTheIndex() async throws {
        let (root, store, sink) = try await fixture([("要删的", "正文")])
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try #require(store.snapshot.items.first?.id)
        await waitUntil { sink.indexed.contains { $0.id == id } }

        store.selection = [id]
        store.requestTrashSelection()
        await store.confirmDelete()
        await waitUntil { sink.removed.contains(id) }
        #expect(sink.removed.contains(id))
    }

    @Test func turningTheIndexOffEmptiesTheSystemIndex() async throws {
        let (root, store, sink) = try await fixture([("甲", "正文")])
        defer {
            UserDefaults.standard.removeObject(forKey: LibraryStore.spotlightDefaultsKey)
            try? FileManager.default.removeItem(at: root)
        }
        await waitUntil { !sink.indexed.isEmpty }

        store.spotlightEnabled = false
        await waitUntil { sink.clears == 1 }
        #expect(sink.clears == 1)
        #expect(sink.indexed.isEmpty)
    }

    @Test func openingFromSpotlightShowsTheItemInTheWholeLibrary() async throws {
        let (root, store, _) = try await fixture([("甲", "正文"), ("乙", "正文")])
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try #require(store.snapshot.items.first { $0.title == "乙" }?.id)

        store.scope = .favorites
        store.query = "甲"
        await store.searchTask?.value

        #expect(store.openFromSpotlight(id))
        #expect(store.scope == .all)
        #expect(store.query.isEmpty)
        #expect(store.selection == [id])
        #expect(!store.openFromSpotlight("missing"))
    }
}
