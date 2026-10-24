import Foundation
import Testing
@testable import LibraryCore

@Suite(.serialized)
final class InboxScannerTests {
    private var folder: URL!

    init() throws {
        folder = testTemporaryDirectory.appendingPathComponent("inbox-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// Writes a file and backdates it so the settle window has already passed.
    @discardableResult
    private func write(_ name: String, _ text: String, age: TimeInterval = 5) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    @Test func newFilesAreOfferedUntilTheyAreRemembered() throws {
        let url = try write("合同.md", "正文")
        let first = InboxScanner.candidates(in: folder, processed: [:])
        #expect(first.map(\.url.lastPathComponent) == ["合同.md"])
        let signature = try #require(first.first?.signature)

        let remembered = InboxScanner.candidates(in: folder, processed: ["合同.md": signature])
        #expect(remembered.isEmpty)

        // A changed file has a new signature, so it is tried again.
        try write("合同.md", "正文改了")
        let changed = InboxScanner.candidates(in: folder, processed: ["合同.md": signature])
        #expect(changed.count == 1)
        #expect(changed.first?.signature != signature)
    }

    @Test func hiddenFilesFoldersAndFilesStillBeingWrittenAreSkipped() throws {
        try write(".DS_Store", "x")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("子目录"), withIntermediateDirectories: true)
        _ = try write("正在写.md", "半截", age: 0)
        let fresh = try write("刚刚出现.md", "内容", age: 0.2)

        let candidates = InboxScanner.candidates(in: folder, processed: [:])
        #expect(candidates.isEmpty)

        // Once both have settled they show up, oldest first.
        let later = InboxScanner.candidates(in: folder, processed: [:], now: Date().addingTimeInterval(2))
        #expect(later.map(\.url.lastPathComponent) == ["刚刚出现.md", "正在写.md"])
        // Enumeration returns the canonical /private/var path, so compare resolved ones.
        #expect(later.first?.url.resolvingSymlinksInPath().path == fresh.resolvingSymlinksInPath().path)
    }

    @Test func candidatesArriveOldestFirst() throws {
        try write("第二份.md", "b", age: 2)
        try write("第一份.md", "a", age: 9)
        let candidates = InboxScanner.candidates(in: folder, processed: [:])
        #expect(candidates.map(\.url.lastPathComponent) == ["第一份.md", "第二份.md"])
    }

    @Test func stateSurvivesARoundTripThroughTheLibrary() throws {
        let root = folder.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var state = InboxState()
        state.mark("合同.md", signature: "12|34")
        state.lastError = "合同.md：无法读取"
        state.save(in: root)

        let loaded = InboxState.load(from: root)
        #expect(loaded.processed == ["合同.md": "12|34"])
        #expect(loaded.lastError == "合同.md：无法读取")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(InboxState.fileName).path))
    }

    @Test func rememberingStopsGrowingPastTheLimit() {
        var state = InboxState()
        for index in 0...InboxScanner.rememberedFiles {
            state.mark("文件\(index).md", signature: "\(index)|0")
        }
        #expect(state.processed.count == InboxScanner.rememberedFiles)
    }
}
