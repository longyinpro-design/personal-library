import AppKit
import LibraryCore
import SwiftUI

struct SourceTextPreview: View {
    let url: URL
    let position: SourcePosition
    @ViewState<SourceTextDocument?> private var document = nil
    @ViewState<String?> private var failure = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let document {
                Text("第 \(position.line) 行" + (position.column.map { "，第 \($0) 列" } ?? "") + " · 共 \(document.lineCount) 行")
                    .font(.callout).foregroundStyle(.secondary)
                SourceTextView(document: document)
                    .accessibilityLabel("文件内容，第 \(position.line) 行")
            } else if let failure {
                ContentUnavailableView("无法定位文件行", systemImage: "doc.text.magnifyingglass", description: Text(failure))
            } else { ProgressView("正在读取文本…") }
        }
        .task(id: url) {
            document = nil; failure = nil
            do {
                let value = try await Task.detached { try SourceTextDocument.load(url, at: position) }.value
                guard !Task.isCancelled else { return }
                document = value
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

private struct SourceTextView: NSViewRepresentable {
    let document: SourceTextDocument

    func makeNSView(context: Context) -> SourceTextScrollView { SourceTextScrollView(document: document) }
    func updateNSView(_ view: SourceTextScrollView, context: Context) {}
}

/// Position only after both the viewport and the text's full layout have sizes.
/// Deferring one run-loop turn can still precede NSTextView's long-file layout.
final class SourceTextScrollView: NSScrollView {
    private var pendingSelection: NSRange?

    init(document: SourceTextDocument) {
        pendingSelection = document.selection
        super.init(frame: .zero)
        hasVerticalScroller = true; hasHorizontalScroller = true
        borderType = .bezelBorder
        let text = NSTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textColor = .textColor; text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = text.maxSize
        documentView = text
        text.string = document.text
        text.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.25), forCharacterRange: document.lineRange)
        text.setSelectedRange(document.selection)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard let range = pendingSelection, contentSize.width > 0, contentSize.height > 0,
              let text = documentView as? NSTextView, let container = text.textContainer else { return }
        pendingSelection = nil
        text.minSize = contentSize
        text.layoutManager?.ensureLayout(for: container)
        text.sizeToFit()
        text.scrollRangeToVisible(range)
    }
}
