import Foundation
import Testing
@testable import LibraryCore

@Suite(.serialized)
final class LibraryTagTests {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("Library") }
    private var repository: LibraryRepository!

    init() throws {
        temporary = testTemporaryDirectory.appendingPathComponent("tags-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        repository = try LibraryRepository(root: root)
    }

    deinit { try? FileManager.default.removeItem(at: temporary) }

    private func note(_ title: String, body: String = "正文") async throws -> String {
        try await repository.saveNote(title: title, body: body, kind: .note)
    }

    @Test func settingTagsCreatesThemAndShowsCounts() async throws {
        let a = try await note("甲")
        let b = try await note("乙")
        try await repository.setTags(["合同", "法务"], for: [a])
        try await repository.setTags(["合同"], for: [b])

        let snapshot = try await repository.snapshot()
        #expect(snapshot.tags.map(\.name) == ["合同", "法务"])
        #expect(snapshot.tags.first { $0.name == "合同" }?.count == 2)
        #expect(snapshot.items.first { $0.id == a }?.tags == ["合同", "法务"])

        // Setting a new list replaces the old one for that item only.
        try await repository.setTags(["归档"], for: [a])
        let updated = try await repository.snapshot()
        #expect(updated.items.first { $0.id == a }?.tags == ["归档"])
        #expect(updated.items.first { $0.id == b }?.tags == ["合同"])
        #expect(updated.tags.first { $0.name == "归档" }?.count == 1)
        #expect(updated.tags.first { $0.name == "法务" }?.count == 0)
    }

    @Test func addingAndRemovingTagsLeavesTheRestAlone() async throws {
        let id = try await note("资料")
        try await repository.addTags(["合同"], to: [id])
        try await repository.addTags(["法务"], to: [id])
        #expect(try await repository.snapshot().items.first?.tags == ["合同", "法务"])

        try await repository.removeTags(["合同"], from: [id])
        let snapshot = try await repository.snapshot()
        #expect(snapshot.items.first?.tags == ["法务"])
        // Removing the last link keeps the tag itself, so it can be reused.
        #expect(snapshot.tags.contains { $0.name == "合同" })
    }

    @Test func deletingATagKeepsTheItems() async throws {
        let id = try await note("资料")
        try await repository.addTags(["合同"], to: [id])
        let tag = try #require(try await repository.snapshot().tags.first)

        try await repository.deleteTag(id: tag.id)
        let snapshot = try await repository.snapshot()
        #expect(snapshot.tags.isEmpty)
        #expect(snapshot.items.map(\.id) == [id])
        #expect(snapshot.items.first?.tags.isEmpty == true)
    }

    @Test func deletingAnItemDropsOnlyItsLinks() async throws {
        let id = try await note("资料")
        let other = try await note("留下的")
        try await repository.addTags(["合同"], to: [id, other])

        _ = try await repository.permanentlyDelete(ids: [id])
        let snapshot = try await repository.snapshot()
        #expect(snapshot.items.map(\.id) == [other])
        #expect(snapshot.tags.first?.count == 1)
    }

    @Test func tagFilterAndTagPrefixReturnTheSameItems() async throws {
        let a = try await note("合同甲", body: "付款方式")
        let b = try await note("合同乙", body: "付款方式")
        _ = try await note("其他", body: "付款方式")
        try await repository.addTags(["法务"], to: [a, b])

        var filter = LibrarySearchFilter()
        filter.tagName = "法务"
        let clicked = try await repository.search(query: "付款", filter: filter)
        let typed = try await repository.search(query: "付款 tag:法务")
        #expect(clicked.items.map(\.id) == typed.items.map(\.id))
        #expect(clicked.items.count == 2)
    }

    @Test func taggingOnItsOwnListsTheTaggedItems() async throws {
        let a = try await note("甲")
        _ = try await note("乙")
        try await repository.addTags(["归档"], to: [a])

        let results = try await repository.search(query: "tag:归档")
        #expect(results.items.map(\.id) == [a])
        // The prefix is not treated as a search word.
        #expect(try await repository.search(query: "tag:归档 甲").items.map(\.id) == [a])
    }

    @Test func renamingOntoAnExistingTagIsRejected() async throws {
        let id = try await note("资料")
        try await repository.addTags(["合同", "法务"], to: [id])
        let tags = try await repository.snapshot().tags
        let legal = try #require(tags.first { $0.name == "法务" })

        await #expect(throws: Error.self) { try await repository.renameTag(id: legal.id, to: "合同") }
        try await repository.renameTag(id: legal.id, to: "合规")
        let renamed = try await repository.snapshot()
        #expect(Set(renamed.tags.map(\.name)) == ["合同", "合规"])
    }
}
