import AppKit
import SwiftUI

/// The menu bar item: a small pad for a thought, without leaving what you are doing.
struct QuickCaptureView: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.openWindow) private var openWindow

    @State private var title = ""
    @State private var text = ""
    @State private var tags = ""
    @State private var pending: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("快速记一条").font(.system(size: 12, weight: .semibold))
            TextField("标题（可留空，取正文第一行）", text: $title)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $text)
                .font(.system(size: 12))
                .frame(height: 120)
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary) }
            TextField("标签，用逗号分隔", text: $tags)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button("粘贴剪贴板") { paste() }
                Spacer()
                Button("保存") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
            }
            .controlSize(.small)

            Divider()

            HStack {
                Button("打开资料库") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "library")
                }
                Spacer()
                Text(store.status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 330)
    }

    private var canSave: Bool {
        store.ready && pending == nil && !(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func paste() {
        guard let pasted = NSPasteboard.general.string(forType: .string),
              !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = pasted
        if title.isEmpty { title = LibraryCapture.normalizeTitle("", body: pasted) }
    }

    private func save() {
        guard canSave else { return }
        let parsedTags = tags.split(whereSeparator: { ",，、;； ".contains($0) }).map(String.init)
        pending = store.captureNote(title: title, body: text, tags: parsedTags)
        Task { @MainActor in
            await pending?.value
            pending = nil
            title = ""; text = ""; tags = ""
        }
    }
}
