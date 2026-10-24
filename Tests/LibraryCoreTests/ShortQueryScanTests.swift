import Foundation
import Testing
@testable import LibraryCore

/// Two-character queries have no trigram entry, so they scan bodies. These check
/// that splitting that scan across connections returns exactly what one query
/// would, including ordering and scope filters.
@Suite(.serialized)
final class ShortQueryScanTests {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("Library") }

    init() throws {
        temporary = testTemporaryDirectory.appendingPathComponent("scan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: temporary) }

    private func seed() async throws -> (LibraryRepository, LibraryRepository) {
        let split = try LibraryRepository(root: root, scanMinimumBytes: 0)
        let single = try LibraryRepository(root: root, scanMinimumBytes: .max)
        for index in 0..<12 {
            _ = try await split.saveNote(title: "资料 \(index)",
                                         body: index.isMultiple(of: 2) ? "本合同约定了付款方式，编号 \(index)" : "无关的正文 \(index)",
                                         kind: .note)
        }
        _ = try await split.saveNote(title: "只有短词", body: "结尾就是合同", kind: .note)
        return (split, single)
    }

    @Test func splitScanMatchesSingleQueryForShortTerms() async throws {
        let (split, single) = try await seed()

        let a = try await split.search(query: "合同")
        let b = try await single.search(query: "合同")
        #expect(a.items.map(\.id) == b.items.map(\.id))
        #expect(a.items.count == 7)
        // A match at the very end of a body is found by both paths.
        #expect(a.items.contains { $0.title == "只有短词" })
    }

    @Test func splitScanKeepsUpdatedAtOrderAcrossRanges() async throws {
        let (split, single) = try await seed()
        let a = try await split.search(query: "付款")
        let b = try await single.search(query: "付款")
        let dates = a.items.map(\.updatedAt)
        #expect(dates == dates.sorted(by: >))
        #expect(a.items.map(\.id) == b.items.map(\.id))
    }

    @Test func splitScanHonoursScopeFilters() async throws {
        let repo = try LibraryRepository(root: root, scanMinimumBytes: 0)
        let collection = try await repo.createCollection(name: "合同目录")
        for index in 0..<6 {
            _ = try await repo.saveNote(title: "归类 \(index)", body: "合同正文 \(index)", kind: .note, collectionID: collection)
        }
        _ = try await repo.saveNote(title: "未归类", body: "合同正文", kind: .note)

        var filter = LibrarySearchFilter()
        filter.collectionID = collection
        let scoped = try await repo.search(query: "合同", filter: filter)
        #expect(scoped.items.count == 6)
        #expect(scoped.items.allSatisfy { $0.collectionID == collection })
    }

    @Test func mixedLongAndShortTermsReturnOnlyRowsWithBoth() async throws {
        let (split, single) = try await seed()
        let a = try await split.search(query: "合同 编号")
        let b = try await single.search(query: "合同 编号")
        #expect(a.items.map(\.id) == b.items.map(\.id))
        #expect(a.items.count == 6)
    }
}
