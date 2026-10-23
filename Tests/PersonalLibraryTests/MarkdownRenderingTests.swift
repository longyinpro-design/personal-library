import Foundation
import MarkdownUI
import Testing
@testable import LibraryCore
@testable import PersonalLibrary

@MainActor
struct MarkdownRenderingTests {
    @Test func onlyMarkdownFilesAndEditableNotesUseMarkdown() {
        for (kind, path, expected) in [(ItemKind.document, "Files/guide.md", true),
                                       (.document, "Files/guide.MARKDOWN", true),
                                       (.document, "Files/plain.txt", false),
                                       (.document, "Files/report.docx", false),
                                       (.other, "Files/code.swift", false),
                                       (.note, "", true), (.thought, "", true)] {
            let item = LibraryCore.LibraryItem(id: "1", title: "Title", kind: kind, relativePath: path,
                                              text: "# Heading", extractionNote: nil, byteCount: 0,
                                              createdAt: .distantPast, updatedAt: .distantPast,
                                              collectionID: nil, favorite: false)
            #expect(item.usesMarkdown == expected)
        }
    }

    @Test func documentParsesCodeTablesTasksAndUpdatesContent() async throws {
        let source = """
        # 中文标题

        **加粗**和[网页](https://example.com)。

        - [x] 已完成
        - [ ] 待处理

        | 字段 | 说明 |
        | --- | --- |
        | ID | 编号 |

        ```swift
        let value = "<tag> & 中文"
        ```
        """
        let document = MarkdownDocument()
        await document.load(source)
        let rendered = try #require(document.content).renderHTML()
        #expect(rendered.contains("<h1>中文标题</h1>"))
        #expect(rendered.contains("<table>"))
        #expect(rendered.contains("type=\"checkbox\""))
        #expect(rendered.contains("language-swift"))
        #expect(rendered.contains("&lt;tag&gt; &amp; 中文"))
        await document.load("## 更新后的正文")
        #expect(document.content?.renderPlainText() == "更新后的正文")
    }

    @Test func cancelledParseCanBeRetriedWithoutPublishingOldContent() async {
        let document = MarkdownDocument()
        let old = Task { await document.load(String(repeating: "# 旧内容\n\n", count: 10_000)) }
        old.cancel()
        await document.load("# 当前内容")
        await old.value
        #expect(document.content?.renderPlainText() == "当前内容")
        await document.load("# 当前内容")
        #expect(document.content?.renderPlainText() == "当前内容")
    }

    @Test func linksOnlyOpenExplicitWebDestinations() throws {
        for value in ["https://example.com/path?q=1#part", "http://localhost:8080/", "HTTPS://example.com/"] {
            #expect(MarkdownLinkPolicy.opensInBrowser(try #require(URL(string: value))))
        }
        for value in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hello", "smb://host/share", "guide.md", "#section", "https:/relative"] {
            #expect(!MarkdownLinkPolicy.opensInBrowser(try #require(URL(string: value))))
        }
    }
}
