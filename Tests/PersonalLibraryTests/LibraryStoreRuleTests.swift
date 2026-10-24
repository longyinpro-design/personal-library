import Foundation
import LibraryCore
import Testing
@testable import PersonalLibrary

@MainActor
struct LibraryStoreRuleTests {
    private func fixture() async throws -> (URL, LibraryStore) {
        let root = testTemporaryDirectory.appendingPathComponent("store-rules-" + UUID().uuidString)
        let library = root.appendingPathComponent("library")
        let repository = try LibraryRepository(root: library)
        _ = try await repository.saveNote(title: "已有资料", body: "正文", kind: .note, collectionID: nil)
        let store = LibraryStore(root: library)
        await store.load()
        return (root, store)
    }

    private func write(_ name: String, _ text: String, in folder: URL, age: TimeInterval? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let age {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)],
                                                  ofItemAtPath: url.path)
        }
        return url
    }

    @Test func savingRulesDropsEmptyOnesAndKeepsTheRest() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        store.saveRules([
            LibraryRule(match: "  "),
            LibraryRule(match: " 合同 ", collection: " ", tags: ["待归档"]),
            LibraryRule(match: "", tags: ["没有匹配词"])
        ])

        #expect(store.rules.count == 1)
        #expect(store.rules.first?.match == "合同")
        #expect(store.rules.first?.collection == nil)
        #expect(store.status.contains("1 条导入规则"))

        let stored = LibraryRuleStore.load(from: store.root)
        #expect(stored == store.rules)
        #expect(store.ruleSummary.contains("合同"))
    }

    @Test func importingAppliesTheSavedRules() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.saveRules([LibraryRule(match: "合同", collection: "合同档案", tags: ["待归档"])])
        let source = try write("2026合同.md", "# 合同", in: root)

        await store.importFiles([source])?.value

        let imported = try #require(store.snapshot.items.first { $0.title == "2026合同.md" })
        #expect(imported.tags == ["待归档"])
        #expect(store.snapshot.collections.contains { $0.id == imported.collectionID && $0.name == "合同档案" })
        #expect(store.status.contains("按规则整理了 1 项"))
    }

    @Test func inboxFilesGoThroughTheSameRules() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        store.saveRules([LibraryRule(match: "发票", tags: ["财务"])])
        _ = try write("发票-九月.md", "金额", in: inbox, age: 5)

        store.startWatchingInbox(at: inbox)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !store.snapshot.items.contains(where: { $0.title == "发票-九月.md" }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        store.stopWatchingInbox()

        let imported = try #require(store.snapshot.items.first { $0.title == "发票-九月.md" })
        #expect(imported.tags == ["财务"])
    }
}
