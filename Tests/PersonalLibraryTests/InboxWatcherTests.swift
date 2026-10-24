import Foundation
import Testing
@testable import PersonalLibrary

@MainActor
struct InboxWatcherTests {
    private func folder() throws -> URL {
        let url = testTemporaryDirectory.appendingPathComponent("watcher-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 4) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test func writingAFileNotifiesOnceTheFolderSettles() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let watcher = InboxWatcher()
        var notifications = 0
        watcher.onChange = { notifications += 1 }
        watcher.start(watching: folder)

        try "内容".write(to: folder.appendingPathComponent("新文件.md"), atomically: true, encoding: .utf8)
        await waitUntil { notifications > 0 }

        #expect(notifications > 0)
        watcher.stop()
    }

    @Test func stoppingEndsTheNotifications() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let watcher = InboxWatcher()
        var notifications = 0
        watcher.onChange = { notifications += 1 }
        watcher.start(watching: folder)
        watcher.stop()

        try "内容".write(to: folder.appendingPathComponent("新文件.md"), atomically: true, encoding: .utf8)
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        #expect(notifications == 0)
        #expect(watcher.folder == nil)
    }
}
