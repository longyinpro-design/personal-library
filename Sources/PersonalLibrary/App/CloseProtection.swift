import AppKit
import SwiftUI

@MainActor
enum CloseProtection {
    enum Decision { case close, save, cancel }

    static func decision(store: LibraryStore) -> Decision {
        if store.isSavingNote || store.isImporting {
            let alert = NSAlert()
            alert.messageText = "资料正在保存或导入"
            alert.informativeText = "请等待操作完成后再退出，确保资料完整保存。"
            alert.addButton(withTitle: "继续等待")
            alert.runModal()
            return .cancel
        }
        guard let draft = store.draft, draft.hasChanges else { return .close }
        let alert = NSAlert()
        alert.messageText = "要保存这篇\(draft.kind.label)吗？"
        alert.informativeText = "有尚未保存的修改。你可以先保存，或返回继续编辑。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "放弃修改")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .close
        default: return .cancel
        }
    }
}

/// Intercept close while forwarding all other window delegate behavior to SwiftUI.
struct WindowCloseProtection: NSViewRepresentable {
    @ObservedObject var store: LibraryStore
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        // SwiftUI must finish its first window-appearance callbacks before delegation changes.
        guard store.ready else { return }
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window, window.delegate !== coordinator else { return }
            coordinator.original = window.delegate
            window.delegate = coordinator
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        let store: LibraryStore
        weak var original: NSWindowDelegate?
        init(store: LibraryStore) { self.store = store }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            switch CloseProtection.decision(store: store) {
            case .close:
                let mayClose = original?.windowShouldClose?(sender) ?? true
                if mayClose { store.draft = nil }
                return mayClose
            case .cancel: return false
            case .save:
                guard let draft = store.draft else { return true }
                Task { @MainActor in
                    do { try await store.save(draft); sender.performClose(nil) }
                    catch { store.errorMessage = error.localizedDescription }
                }
                return false
            }
        }
    }
}
