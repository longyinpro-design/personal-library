import Foundation
import LibraryCore
import Testing
@testable import PersonalLibrary

@MainActor
struct LibraryStoreInboxTests {
    private func fixture() async throws -> (URL, URL, LibraryStore) {
        let root = testTemporaryDirectory.appendingPathComponent("store-inbox-" + UUID().uuidString)
        let library = root.appendingPathComponent("library")
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let repository = try LibraryRepository(root: library)
        _ = try await repository.saveNote(title: "已有资料", body: "正文", kind: .note, collectionID: nil)
        let store = LibraryStore(root: library)
        await store.load()
        return (root, inbox, store)
    }

    /// Writes a file and backdates it, so the settle window has already passed.
    private func write(_ name: String, _ text: String, into folder: URL) throws {
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-5)],
                                              ofItemAtPath: url.path)
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test func watchingAFolderImportsNewFiles() async throws {
        let (root, inbox, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("合同.md", "# 合同\n\n正文", into: inbox)

        store.startWatchingInbox(at: inbox)
        await waitUntil { store.snapshot.items.contains { $0.title == "合同" } }

        #expect(store.inboxFolder == inbox)
        #expect(store.snapshot.items.count == 2)
        #expect(store.status.contains("收件箱"))
        #expect(store.inboxError == nil)
    }

    @Test func theSameFileIsNotImportedTwice() async throws {
        let (root, inbox, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("流程.md", "步骤一", into: inbox)
        store.startWatchingInbox(at: inbox)
        await waitUntil { store.snapshot.items.contains { $0.title == "流程" } }
        let afterFirst = store.snapshot.items.count

        // No candidates left, so a manual pass has nothing to do.
        #expect(store.checkInbox() == nil)
        #expect(store.snapshot.items.count == afterFirst)
    }

    @Test func changedFilesAreTriedAgainButDuplicatesAreSkipped() async throws {
        let (root, inbox, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("需求.md", "第一版", into: inbox)
        store.startWatchingInbox(at: inbox)
        await waitUntil { store.snapshot.items.contains { $0.title == "需求" } }
        let afterFirst = store.snapshot.items.count

        // Same bytes with a new timestamp: still a duplicate by content.
        try write("需求.md", "第一版", into: inbox)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-5)],
                                              ofItemAtPath: inbox.appendingPathComponent("需求.md").path)
        await store.checkInbox()?.value

        #expect(store.snapshot.items.count == afterFirst)
        #expect(store.status.contains("跳过"))
    }

    @Test func theFolderIsPickedUpAgainOnTheNextLaunch() async throws {
        let (root, inbox, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var state = InboxState()
        state.folderBookmark = try inbox.bookmarkData(includingResourceValuesForKeys: nil, relativeTo: nil)
        state.save(in: store.root)
        try write("次日.md", "内容", into: inbox)

        let relaunched = LibraryStore(root: store.root)
        await relaunched.load()
        await waitUntil { relaunched.snapshot.items.contains { $0.title == "次日" } }

        #expect(relaunched.inboxFolder?.lastPathComponent == inbox.lastPathComponent)
        #expect(relaunched.snapshot.items.count == 2)
        relaunched.stopWatchingInbox()
    }

    @Test func stoppingLeavesTheFolderAlone() async throws {
        let (root, inbox, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.startWatchingInbox(at: inbox)
        store.stopWatchingInbox()
        let before = store.snapshot.items.count

        try write("后来的.md", "内容", into: inbox)
        #expect(store.inboxFolder == nil)
        #expect(store.checkInbox() == nil)
        #expect(store.snapshot.items.count == before)
        #expect(InboxState.load(from: store.root).folderBookmark == nil)
    }
}
