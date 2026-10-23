import AppKit
import LibraryCore
import Testing
@testable import PersonalLibrary

@MainActor
struct SourceTextPreviewTests {
    @Test func longDocumentPositionsAfterViewportLayoutAndPreservesUserScroll() throws {
        let body = (1...3000).map { "第 \($0) 行：\t这是一行用于长文本定位的中文😀代码。" }.joined(separator: "\n")
        let document = try SourceTextDocument(text: body, at: .init(line: 1630))
        let view = SourceTextScrollView(document: document)
        // Construction begins at zero size, just as in NSViewRepresentable.
        view.layout()
        view.frame = NSRect(x: 0, y: 0, width: 780, height: 520)
        view.layoutSubtreeIfNeeded()
        view.layout()
        let text = try #require(view.documentView as? NSTextView)
        let manager = try #require(text.layoutManager), container = try #require(text.textContainer)
        let glyph = manager.glyphRange(forCharacterRange: document.selection, actualCharacterRange: nil)
        let target = manager.boundingRect(forGlyphRange: glyph, in: container).offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
        #expect(view.contentView.bounds.minY > 0)
        #expect(text.visibleRect.intersects(target))
        #expect(text.selectedRange() == document.selection)
        #expect(!text.isEditable && text.isSelectable)
        // A later layout must not snap back after the reader manually scrolls.
        text.scroll(NSPoint.zero)
        view.layout()
        #expect(view.contentView.bounds.minY == 0)
    }
}
