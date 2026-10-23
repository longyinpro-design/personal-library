import AppKit
import Foundation
import LibraryCore
import SwiftUI
import Testing
@testable import PersonalLibrary

@MainActor
struct BodyTextRenderingTests {
    @Test func chunksCoverEveryCharacterAndStayWithinTheLimit() {
        let text = (1...400).map { "第 \($0) 行：电力数据与中文内容。" }.joined(separator: "\n")
        let chunks = BodyTextChunk.split(text, limit: 500)
        #expect(!chunks.isEmpty)
        #expect(chunks.allSatisfy { !$0.text.isEmpty && $0.text.count <= 500 })
        #expect(chunks.map(\.id) == Array(0..<chunks.count))
        // Newline boundaries are replaced by the stack's line break, so joining
        // with a newline reproduces the original document.
        #expect(chunks.map(\.text).joined(separator: "\n") == text)
    }

    @Test func longSingleLineFallsBackToHardCutsWithoutLosingText() {
        let text = String(repeating: "abc中文😀", count: 5_000)
        let chunks = BodyTextChunk.split(text, limit: 4_000)
        #expect(chunks.count == 8)
        #expect(chunks.allSatisfy { $0.text.count <= 4_000 })
        #expect(chunks.map(\.text).joined() == text)
    }

    @Test func graphemeClustersAreNeverSplit() {
        let text = String(repeating: "e\u{301}👨‍👩‍👧‍👦", count: 3_000)
        let chunks = BodyTextChunk.split(text, limit: 100)
        #expect(chunks.map(\.text).joined() == text)
        #expect(chunks.allSatisfy { $0.text.count <= 100 })
    }

    @Test func modelReusesChunksUntilTheTextChanges() {
        let model = BodyTextModel()
        let first = model.chunks(for: "第一版正文")
        let second = model.chunks(for: "第一版正文")
        #expect(first.map(\.id) == second.map(\.id))
        let changed = model.chunks(for: "第二版正文")
        #expect(changed.map(\.text) == ["第二版正文"])
    }
}

@MainActor
struct MarkdownLazyRenderingTests {
    @Test func anchorNavigationReachesDistantLazySection() async throws {
        _ = NSApplication.shared
        let source = (0..<40).map { index in
            "# 标题\(index)\n\n" + String(repeating: "第 \(index) 节的正文，用于撑开阅读高度。\n\n", count: 8)
        }.joined()
        let request = ReadingRequest(itemID: "doc", fragment: "标题39")
        let hosting = NSHostingView(rootView: ReaderHarness(source: source, request: request))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            // Suspending lets the document task publish and SwiftUI lay out the
            // lazy stack; blocking the main actor with a run loop would starve it.
            try? await Task.sleep(for: .milliseconds(30))
            hosting.layoutSubtreeIfNeeded()
            if let scroll = Self.scrollView(in: hosting), scroll.documentVisibleRect.origin.y > 1_000 { break }
        }
        let scroll = try #require(Self.scrollView(in: hosting))
        #expect(scroll.documentVisibleRect.origin.y > 1_000)
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }

    private struct ReaderHarness: View {
        let source: String
        let request: ReadingRequest

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    MarkdownReader(source: source,
                                   imageContext: MarkdownImageContext(itemID: "doc", basePath: nil),
                                   imageIssues: [],
                                   isCopyingImages: false,
                                   chooseImageDirectory: {},
                                   copyImages: {},
                                   readingRequest: request,
                                   followLink: { _ in },
                                   scrollTo: { proxy.scrollTo($0, anchor: .top) },
                                   reportError: { _ in })
                        .padding(28)
                }
            }
        }
    }
}
