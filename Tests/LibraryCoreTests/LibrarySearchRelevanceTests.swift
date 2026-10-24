import Foundation
import Testing
@testable import LibraryCore

@Suite(.serialized)
final class LibrarySearchRelevanceTests {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("Library") }

    init() throws {
        temporary = testTemporaryDirectory.appendingPathComponent("relevance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: temporary) }

    private func item(_ id: String, title: String, body: String = "正文",
                      kind: ItemKind = .note, updated: TimeInterval = 0) -> LibraryItem {
        LibraryItem(id: id, title: title, kind: kind, relativePath: nil, text: body,
                    extractionNote: nil, byteCount: 0, createdAt: Date(timeIntervalSince1970: 0),
                    updatedAt: Date(timeIntervalSince1970: updated), collectionID: nil, favorite: false)
    }

    @Test func relevanceTiersFollowTitleThenBody() {
        let query = "巴西 验收"
        #expect(LibrarySearch.relevance(of: item("a", title: "巴西 验收"), query: query) == .titleExact)
        #expect(LibrarySearch.relevance(of: item("b", title: "巴西 验收 报告"), query: query) == .titlePrefix)
        #expect(LibrarySearch.relevance(of: item("c", title: "巴西 项目 验收 单"), query: query) == .titleAllTerms)
        #expect(LibrarySearch.relevance(of: item("d", title: "巴西 项目"), query: query) == .titleSomeTerms)
        #expect(LibrarySearch.relevance(of: item("e", title: "项目"), query: query) == .bodyOnly)
        #expect(LibrarySearch.relevance(of: item("f", title: ""), query: query) == .bodyOnly)
        #expect(LibrarySearch.relevance(of: item("g", title: "巴西"), query: "  ") == .bodyOnly)
    }

    @Test func relevanceIgnoresCaseAndWidth() {
        #expect(LibrarySearch.relevance(of: item("a", title: "Swift 教程"), query: "swift 教程") == .titleExact)
        #expect(LibrarySearch.relevance(of: item("b", title: "ＳＷＩＦＴ 指南"), query: "swift") == .titlePrefix)
    }

    @Test func titleHitsComeBeforeBodyHitsEvenWhenOlder() async throws {
        let repo = try LibraryRepository(root: root)
        let buried = try await repo.saveNote(title: "无关资料", body: "深处提到 巴西 验收", kind: .note)
        let titled = try await repo.saveNote(title: "巴西 验收", body: "另有正文", kind: .note)
        let prefixed = try await repo.saveNote(title: "巴西 验收 记录", body: "另有正文", kind: .note)

        let results = try await repo.search(query: "巴西 验收")
        #expect(results.items.map(\.id) == [titled, prefixed, buried])
    }

    @Test func tiesKeepUpdatedDescendingThenID() async throws {
        let repo = try LibraryRepository(root: root)
        let older = try await repo.saveNote(title: "同样标题 一", body: "正文", kind: .note)
        let newer = try await repo.saveNote(title: "同样标题 二", body: "再次更新", kind: .note)
        _ = try await repo.saveNote(id: older, title: "同样标题 一", body: "重新保存", kind: .note)

        let first = try await repo.search(query: "同样标题")
        let second = try await repo.search(query: "同样标题")
        #expect(first.items.map(\.id) == second.items.map(\.id))
        #expect(first.items.count == 2)
        _ = newer
        #expect(first.items.map(\.updatedAt) == first.items.map(\.updatedAt).sorted(by: >))
    }

    @Test func shortQueryFallbackKeepsTheSameRanking() async throws {
        let repo = try LibraryRepository(root: root)
        let buried = try await repo.saveNote(title: "笔记", body: "今天讨论了文件归档", kind: .note)
        let titled = try await repo.saveNote(title: "文件 归档", body: "正文", kind: .note)

        let results = try await repo.search(query: "文件")
        #expect(results.items.map(\.id) == [titled, buried])
    }
}
