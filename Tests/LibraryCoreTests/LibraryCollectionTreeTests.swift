import Foundation
import Testing
@testable import LibraryCore

@Suite(.serialized)
struct LibraryCollectionTreeTests {
    private func makeRepository() throws -> (LibraryRepository, URL) {
        let root = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try LibraryRepository(root: root), root)
    }

    @Test func foldersNestAndReportTheirParent() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try await repository.createCollection(name: "2025")
        let child = try await repository.createCollection(name: "合同", parentID: parent)
        let snapshot = try await repository.snapshot()
        #expect(snapshot.collections.first { $0.id == parent }?.parentID == nil)
        #expect(snapshot.collections.first { $0.id == child }?.parentID == parent)
    }

    @Test func aFolderCannotMoveUnderItsOwnChild() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try await repository.createCollection(name: "上司")
        let child = try await repository.createCollection(name: "下属", parentID: parent)
        await #expect(throws: (any Error).self) {
            try await repository.moveCollection(id: parent, to: child)
        }
        await #expect(throws: (any Error).self) {
            try await repository.moveCollection(id: parent, to: parent)
        }
        let snapshot = try await repository.snapshot()
        #expect(snapshot.collections.first { $0.id == child }?.parentID == parent)
    }

    @Test func movingAFolderKeepsItsItemsAndChildren() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await repository.createCollection(name: "旧位置")
        let second = try await repository.createCollection(name: "新位置")
        let child = try await repository.createCollection(name: "子目录", parentID: first)
        let id = try await repository.saveNote(title: "笔记", body: "正文", kind: .note)
        try await repository.organize(ids: [id], collectionID: first)

        try await repository.moveCollection(id: first, to: second)

        let snapshot = try await repository.snapshot()
        #expect(snapshot.collections.first { $0.id == first }?.parentID == second)
        #expect(snapshot.collections.first { $0.id == child }?.parentID == first)
        #expect(snapshot.items.first { $0.id == id }?.collectionID == first)
    }

    @Test func deletingAFolderMovesChildrenUpAndItemsToTheInbox() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let top = try await repository.createCollection(name: "顶层")
        let middle = try await repository.createCollection(name: "中间", parentID: top)
        let leaf = try await repository.createCollection(name: "叶子", parentID: middle)
        let id = try await repository.saveNote(title: "笔记", body: "正文", kind: .note)
        try await repository.organize(ids: [id], collectionID: middle)

        try await repository.deleteCollection(id: middle)

        let snapshot = try await repository.snapshot()
        #expect(!snapshot.collections.contains { $0.id == middle })
        #expect(snapshot.collections.first { $0.id == leaf }?.parentID == top)
        #expect(snapshot.items.first { $0.id == id }?.collectionID == nil)
        #expect(snapshot.items.contains { $0.id == id })
    }

    @Test func renamingKeepsNamesUniqueAndRejectsEmptyOnes() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try await repository.createCollection(name: "合同")
        _ = try await repository.createCollection(name: "流程")
        try await repository.renameCollection(id: one, to: "合约")
        let snapshot = try await repository.snapshot()
        #expect(snapshot.collections.contains { $0.id == one && $0.name == "合约" })
        await #expect(throws: (any Error).self) {
            try await repository.renameCollection(id: one, to: "流程")
        }
        await #expect(throws: (any Error).self) {
            try await repository.renameCollection(id: one, to: "   ")
        }
    }

    @Test func nestingIsCapped() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        var parent: String?
        for level in 1...LibraryRepository.maximumCollectionDepth {
            parent = try await repository.createCollection(name: "第 \(level) 层", parentID: parent)
        }
        await #expect(throws: (any Error).self) {
            try await repository.createCollection(name: "太深了", parentID: parent)
        }
    }

    @Test func creatingUnderAMissingParentIsRefused() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            try await repository.createCollection(name: "孤儿", parentID: "missing")
        }
    }
}
