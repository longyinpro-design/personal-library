import AppIntents
import AppKit
import Foundation
import LibraryCore

/// Saves a note without opening the window. Uses the same library root and the
/// same save path as the menu bar item, so Shortcuts and the app agree.
struct CaptureNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "保存笔记到资料库"
    static var description: IntentDescription = IntentDescription(
        "把一段文字存成资料库里的笔记，不需要先打开 App。"
    )
    static var openAppWhenRun = false

    @Parameter(title: "标题")
    var title: String

    @Parameter(title: "正文")
    var body: String

    @Parameter(title: "标签")
    var tags: [String]?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let saved = try await LibraryCapture.saveNote(title: title, body: body,
                                                      tags: tags ?? [],
                                                      in: LibraryLocation.defaultRoot())
        return .result(dialog: "已保存「\(saved.title)」")
    }
}

/// Brings the window forward; useful as the last step of a shortcut.
struct OpenLibraryIntent: AppIntent {
    static var title: LocalizedStringResource = "打开资料库"
    static var description: IntentDescription = IntentDescription("打开个人资料库窗口。")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NSApp.activate(ignoringOtherApps: true)
        return .result(dialog: "已打开资料库")
    }
}

struct LibraryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureNoteIntent(),
            phrases: [
                "用 \(.applicationName) 记一条笔记",
                "保存到 \(.applicationName)"
            ],
            shortTitle: "记一条笔记",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenLibraryIntent(),
            phrases: ["打开 \(.applicationName)"],
            shortTitle: "打开资料库",
            systemImageName: "books.vertical"
        )
    }
}
