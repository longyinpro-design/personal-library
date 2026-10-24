import Foundation
import Testing
@testable import LibraryCore

struct ReadingPositionTests {
    private func fixture() async throws -> (URL, LibraryRepository, String) {
        let root = testTemporaryDirectory.appendingPathComponent("reading-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = try LibraryRepository(root: root)
        let id = try await repo.saveNote(title: "长笔记", body: "# 一\n\n## 二", kind: .note, collectionID: nil)
        return (root, repo, id)
    }

    @Test func positionsRoundTripAndClear() async throws {
        let (root, repo, id) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try await repo.readingPositions().isEmpty)
        try await repo.setReadingPosition(Data("{\"markdownSection\":3}".utf8), for: id)
        #expect(try await repo.readingPositions()[id].map { String(decoding: $0, as: UTF8.self) } == "{\"markdownSection\":3}")

        try await repo.setReadingPosition(nil, for: id)
        #expect(try await repo.readingPositions().isEmpty)
    }

    @Test func positionsSurviveReopeningTheLibrary() async throws {
        let (root, repo, id) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await repo.setReadingPosition(Data("{\"bodyChunk\":7}".utf8), for: id)

        let reopened = try LibraryRepository(root: root)
        #expect(try await reopened.readingPositions()[id] != nil)
    }

    @Test func writingAPositionLeavesTheItemUntouched() async throws {
        let (root, repo, id) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try #require(try await repo.snapshot().items.first)

        try await repo.setReadingPosition(Data("{}".utf8), for: id)
        let after = try #require(try await repo.snapshot().items.first)
        #expect(after.updatedAt == before.updatedAt)
        #expect(after.title == before.title)
    }

    @Test func unknownItemIsIgnored() async throws {
        let (root, repo, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await repo.setReadingPosition(Data("{}".utf8), for: "missing")
        #expect(try await repo.readingPositions().isEmpty)
    }
}
