import Foundation
import LibraryCore
import Testing
@testable import PersonalLibrary

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func raise() { lock.lock(); value = true; lock.unlock() }
    var raised: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct LibraryCaptureTests {
    private func root() throws -> URL {
        let root = testTemporaryDirectory.appendingPathComponent("capture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func savesANoteWithTagsAndAnnouncesIt() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let flag = Flag()
        let token = NotificationCenter.default.addObserver(forName: .libraryDidChangeExternally,
                                                           object: nil, queue: nil) { _ in flag.raise() }
        defer { NotificationCenter.default.removeObserver(token) }

        let saved = try await LibraryCapture.saveNote(title: "", body: "第一行标题\n正文内容",
                                                      tags: [" 速记 ", "", "速记"], in: root)
        #expect(saved.title == "第一行标题")
        #expect(flag.raised)

        let repository = try LibraryRepository(root: root)
        let snapshot = try await repository.snapshot()
        #expect(snapshot.items.map(\.title) == ["第一行标题"])
        #expect(snapshot.items.first?.tags == ["速记"])
        let id = try #require(snapshot.items.first?.id)
        #expect(try await repository.body(for: id)?.contains("正文内容") == true)
    }

    @Test func titleFallsBackToTheFirstLineAndThenToAPlaceholder() {
        #expect(LibraryCapture.normalizeTitle("  ", body: "  \n第二行") == "第二行")
        #expect(LibraryCapture.normalizeTitle("", body: "") == "未命名笔记")
        #expect(LibraryCapture.normalizeTitle("已有的", body: "正文") == "已有的")
    }

    @Test func tagsAreTrimmedDeduplicatedAndGuarded() {
        #expect(LibraryCapture.cleanTags(["  合同 ", "合同", "", "TAG:x", "法务"]) == ["合同", "法务"])
    }

    @Test @MainActor func menuBarCaptureLandsInTheOpenLibrary() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        let store = LibraryStore(root: library)
        await store.load()
        await store.captureNote(title: "", body: "随手记\n剪贴板里的想法", tags: ["速记"])?.value
        await store.searchTask?.value

        #expect(store.snapshot.items.map(\.title) == ["随手记"])
        #expect(store.snapshot.items.first.map { store.selection == [$0.id] } == true)
    }
}
