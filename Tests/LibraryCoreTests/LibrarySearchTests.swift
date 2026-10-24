import Foundation
import Testing
@testable import LibraryCore

@Suite(.serialized)
final class LibrarySearchTests {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("Library") }

    init() throws {
        temporary = testTemporaryDirectory.appendingPathComponent("search-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: temporary) }

    @Test func ftsFindsChineseAndEnglishTermsAndFallsBackForShortQueries() async throws {
        let repo = try LibraryRepository(root: root)
        let id = try await repo.saveNote(title: "巴西项目记录", body: "现场验收 Energisa 文件夹", kind: .note)
        _ = try await repo.saveNote(title: "香港项目", body: "香港交付材料", kind: .note)

        let long = try await repo.search(query: "巴西 验收")
        #expect(long.items.map(\.id) == [id])
        #expect(long.presentations[id]?.matchingExcerpt?.contains("验收") == true)
        #expect(long.items[0].text.isEmpty && !long.items[0].textLoaded)

        let short = try await repo.search(query: "文件")
        #expect(short.items.count == 1)
        let title = try await repo.search(query: "香港")
        #expect(title.items.count == 1)
    }

    @Test func mixedTermsTitlesAndEscapedCharactersStaySearchable() async throws {
        let repo = try LibraryRepository(root: root)
        let id = try await repo.saveNote(title: "独特标题", body: "文件夹里的报告 100% 完成 a_b", kind: .note)
        _ = try await repo.saveNote(title: "无关", body: "普通内容", kind: .note)

        #expect(try await repo.search(query: "独特标题").items.map(\.id) == [id])
        #expect(try await repo.search(query: "文件 报告").items.map(\.id) == [id])
        #expect(try await repo.search(query: "文件夹里 报告").items.map(\.id) == [id])
        #expect(try await repo.search(query: "100%").items.map(\.id) == [id])
        #expect(try await repo.search(query: "a_b").items.map(\.id) == [id])
    }

    @Test func searchIndexFollowsUpdatesAndDeletes() async throws {
        let repo = try LibraryRepository(root: root)
        let id = try await repo.saveNote(title: "临时笔记", body: "旧关键词 甲", kind: .note)
        #expect(try await repo.search(query: "旧关键词").items.count == 1)
        _ = try await repo.saveNote(id: id, title: "临时笔记", body: "新关键词 乙", kind: .note)
        #expect(try await repo.search(query: "旧关键词").items.isEmpty)
        #expect(try await repo.search(query: "新关键词").items.count == 1)
        _ = try await repo.permanentlyDelete(ids: [id])
        #expect(try await repo.search(query: "新关键词").items.isEmpty)
    }

    @Test func searchAppliesScopeFiltersAndRecentLimit() async throws {
        let repo = try LibraryRepository(root: root)
        let collection = try await repo.createCollection(name: "项目")
        let inbox = try await repo.saveNote(title: "待整理 巴西", body: "巴西", kind: .note)
        let filed = try await repo.saveNote(title: "已归档 巴西", body: "巴西", kind: .note, collectionID: collection)
        try await repo.setFavorite(id: filed, value: true)
        let thought = try await repo.saveNote(title: "随笔 巴西", body: "巴西", kind: .thought)

        #expect(try await repo.search(query: "巴西", filter: .init(collectionID: collection)).items.map(\.id) == [filed])
        #expect(Set(try await repo.search(query: "巴西", filter: .init(inboxOnly: true)).items.map(\.id)) == Set([inbox, thought]))
        #expect(try await repo.search(query: "巴西", filter: .init(favoritesOnly: true)).items.map(\.id) == [filed])
        #expect(try await repo.search(query: "巴西", filter: .init(kind: .thought)).items.count == 1)
        #expect(try await repo.search(query: "巴西", filter: .init(recentLimit: 1)).items.count == 1)
    }

    @Test func snapshotCarriesPreviewAndLoadsBodyOnDemand() async throws {
        let repo = try LibraryRepository(root: root)
        let body = String(repeating: "长正文", count: 200)
        let id = try await repo.saveNote(title: "长笔记", body: body, kind: .note)
        let state = try await repo.snapshot()
        let item = try #require(state.items.first)
        #expect(item.text.isEmpty && !item.textLoaded)
        #expect(item.preview.hasPrefix("长正文"))
        #expect(try await repo.body(for: id) == body)
        #expect(try await repo.body(for: "missing") == nil)
    }
}
