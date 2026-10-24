import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: LibraryStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Publish the packaged icon when the running application registers with the Dock.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        } else {
            NSLog("Unable to load the packaged AppIcon.icns for the running application.")
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        switch CloseProtection.decision(store: store) {
        case .close: return .terminateNow
        case .cancel: return .terminateCancel
        case .save:
            guard let draft = store.draft else { return .terminateNow }
            Task { @MainActor in
                do { try await store.save(draft); sender.reply(toApplicationShouldTerminate: true) }
                catch { store.errorMessage = error.localizedDescription; sender.reply(toApplicationShouldTerminate: false) }
            }
            return .terminateLater
        }
    }
}

@main
struct PersonalLibraryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = LibraryStore()

    var body: some Scene {
        Window("个人资料库", id: "library") {
            ContentView(store: store)
                .frame(minWidth: 1080, minHeight: 680)
                .background(WindowCloseProtection(store: store))
                .onAppear { delegate.store = store }
                .task { await store.load() }
        }
        .defaultSize(width: 1440, height: 920)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建笔记") { store.newNote() }.keyboardShortcut("n")
                    .disabled(!store.ready || store.draft != nil || store.isImporting)
                Button("写随笔") { store.newNote(kind: .thought) }.keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!store.ready || store.draft != nil || store.isImporting)
                Button("导入文件…") { store.chooseFiles() }.keyboardShortcut("o")
                    .disabled(!store.ready || store.isImporting || store.draft != nil)
                Button("导入资料包…") { store.choosePackage() }.keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(!store.ready || store.isImporting || store.draft != nil)
            }
            CommandGroup(after: .textEditing) {
                Button("搜索资料") { store.focusSearch.toggle() }.keyboardShortcut("f")
            }
        }
        Settings {
            SettingsView(store: store)
        }
    }
}
