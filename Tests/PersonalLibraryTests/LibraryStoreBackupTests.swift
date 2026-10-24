import Foundation
import LibraryCore
import Testing
@testable import PersonalLibrary

@MainActor
struct LibraryStoreBackupTests {
    private func fixture(_ notes: [(String, String)] = [("第一条", "正文")]) async throws -> (URL, URL, LibraryStore) {
        let root = testTemporaryDirectory.appendingPathComponent("store-backup-" + UUID().uuidString)
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

    @Test func openingTheLibraryWritesOneBackupPerDay() async throws {
        let (root, _, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(store.errorMessage == nil)
        #expect(store.backups.count == 1)
        #expect(store.backups.first?.url.deletingLastPathComponent().lastPathComponent == LibraryBackupStore.directoryName)

        // A second launch the same day does not add another copy.
        let again = LibraryStore(root: store.root)
        await again.load()
        #expect(again.backups.count == 1)
    }

    @Test func stagedRestoreIsAppliedOnTheNextLoadAndKeepsTheOldDatabase() async throws {
        let (root, library, store) = try await fixture([("保留的那条", "正文")])
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = try #require(store.backups.first)

        let repo = try LibraryRepository(root: library)
        _ = try await repo.saveNote(title: "备份之后新增", body: "正文", kind: .note, collectionID: nil)
        #expect(try await repo.snapshot().items.count == 2)

        store.prepareRestore(from: backup.url)
        #expect(store.hasPendingRestore)
        #expect(store.pendingRestoreName == backup.name)

        let relaunched = LibraryStore(root: library)
        await relaunched.load()

        #expect(relaunched.errorMessage == nil)
        #expect(relaunched.snapshot.items.count == 1)
        #expect(relaunched.snapshot.items.first?.title == "保留的那条")
        #expect(relaunched.status.contains("已从备份恢复"))
        #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent(LibraryBackupStore.safetyCopyName).path))
        #expect(!relaunched.hasPendingRestore)
    }

    @Test func cancellingAPreparedRestoreKeepsTheLibraryIntact() async throws {
        let (root, library, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = try #require(store.backups.first)

        store.prepareRestore(from: backup.url)
        #expect(store.hasPendingRestore)
        store.cancelPendingRestore()

        #expect(!store.hasPendingRestore)
        #expect(store.pendingRestoreName.isEmpty)
        let relaunched = LibraryStore(root: library)
        await relaunched.load()
        #expect(relaunched.snapshot.items.count == 1)
        #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent(LibraryBackupStore.safetyCopyName).path))
    }

    @Test func restoringSomethingThatIsNotABackupReportsAnErrorWithoutStaging() async throws {
        let (root, _, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = root.appendingPathComponent("说明.txt")
        try "不是备份".write(to: text, atomically: true, encoding: .utf8)

        store.prepareRestore(from: text)

        #expect(!store.hasPendingRestore)
        #expect(store.errorMessage != nil)
        #expect(store.snapshot.items.count == 1)
    }
}
