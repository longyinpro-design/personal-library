import Foundation
import Testing
@testable import LibraryCore

struct SourceTextTests {
    private func origin() -> LibraryItem {
        LibraryItem(id: "origin", title: "guide.md", kind: .document, relativePath: "origin.md",
                    text: "", extractionNote: nil, byteCount: 0, createdAt: .distantPast, updatedAt: .distantPast,
                    collectionID: nil, favorite: false, sourcePaths: ["/source/guide.md"])
    }

    @Test func lineLinksResolvePathsWithoutDecodingLiteralColonSyntax() throws {
        let source = origin(), root = URL(fileURLWithPath: "/library")
        for reference in ["code.swift:12", "./code.swift:12", "/source/code.swift:12", "file:///source/code.swift:12"] {
            #expect(try MarkdownLinks.resolve(URL(string: reference)!, from: source, items: [source], root: root) ==
                    .sourceFile(URL(fileURLWithPath: "/source/code.swift"), position: .init(line: 12), itemID: nil))
        }
        let unicodeLink = "../%E4%B8%AD%E6%96%87%20%E4%BB%A3%E7%A0%81.go:3:2"
        #expect(try MarkdownStructure.parse("[代码](../中文%20代码.go:3:2)").sections[0].markdown.contains(unicodeLink))
        #expect(try MarkdownLinks.resolve(URL(string: unicodeLink)!, from: source, items: [source], root: root) ==
                .sourceFile(URL(fileURLWithPath: "/中文 代码.go"), position: .init(line: 3, column: 2), itemID: nil))
        for name in ["README", "Makefile", "Dockerfile", "config"] {
            #expect(try MarkdownLinks.resolve(URL(string: name + ":12:3")!, from: source, items: [source], root: root) ==
                    .sourceFile(URL(fileURLWithPath: "/source/" + name), position: .init(line: 12, column: 3), itemID: nil))
        }
        #expect(try MarkdownLinks.resolve(URL(string: "./code.swift%3A12")!, from: source, items: [source], root: root) ==
                .localFile(URL(fileURLWithPath: "/source/code.swift:12"), fragment: nil))
        #expect(try MarkdownLinks.resolve(URL(string: "https://example.com/file.go:12")!, from: source, items: [source], root: root) ==
                .web(URL(string: "https://example.com/file.go:12")!))
        for reference in ["javascript:12", "data:12", "smb:12", "vscode:12", "file://server/code.go:12", "code.go:0", "code.go:2:0", "code.go:999999999999999999999999", "code.go:1#heading", "code.go:1?query"] {
            #expect(throws: (any Error).self) { try MarkdownLinks.resolve(URL(string: reference)!, from: source, items: [source], root: root) }
        }
    }

    @Test func lineLinkUsesManagedBytesAfterSourceAndLibraryMove() async throws {
        let temp = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = temp.appendingPathComponent("code.swift")
        try "first\n目标😀行\nlast".write(to: source, atomically: true, encoding: .utf8)
        let root = temp.appendingPathComponent("library")
        do {
            let repo = try LibraryRepository(root: root)
            _ = try await repo.importFiles([source])
        }
        try FileManager.default.moveItem(at: source, to: temp.appendingPathComponent("source-moved.swift"))
        let moved = temp.appendingPathComponent("library-moved")
        try FileManager.default.moveItem(at: root, to: moved)
        let repo = try LibraryRepository(root: moved), items = try await repo.snapshot().items
        let target = try MarkdownLinks.resolve(URL(string: source.absoluteString + ":2:3")!, from: origin(), items: items, root: moved)
        guard case .sourceFile(let url, let position, let id) = target else { Issue.record("Expected managed source file"); return }
        #expect(id == items.first?.id)
        let document = try SourceTextDocument.load(url, at: position)
        #expect((document.text as NSString).substring(with: document.selection) == "😀")
        #expect(url.path.hasPrefix(moved.path))
    }

    @Test func lineAndColumnRangesRespectNewlinesAndUnicode() throws {
        let text = "one\r\n中😀é\rthird\n"
        let line = try SourceTextDocument(text: text, at: .init(line: 2))
        #expect(line.lineCount == 4)
        #expect((text as NSString).substring(with: line.selection) == "中😀é")
        let column = try SourceTextDocument(text: text, at: .init(line: 2, column: 3))
        #expect((text as NSString).substring(with: column.selection) == "é")
        #expect(try SourceTextDocument(text: text, at: .init(line: 4)).selection == NSRange(location: (text as NSString).length, length: 0))
        #expect(try SourceTextDocument(text: "", at: .init(line: 1)).lineCount == 1)
        #expect(throws: (any Error).self) { try SourceTextDocument(text: text, at: .init(line: 5)) }
        #expect(throws: (any Error).self) { try SourceTextDocument(text: text, at: .init(line: 2, column: 5)) }
    }

    @Test func loaderAcceptsTextEncodingsAndRejectsBinaryOversizeOrDirectory() throws {
        let temp = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("text")
        let text = "首行\n第二行"
        for data in [Data(text.utf8), Data([0xEF,0xBB,0xBF]) + Data(text.utf8), Data([0xFF,0xFE]) + text.data(using: .utf16LittleEndian)!, Data([0xFE,0xFF]) + text.data(using: .utf16BigEndian)!] {
            try data.write(to: file)
            #expect(try SourceTextDocument.load(file, at: .init(line: 2)).text == text)
        }
        for data in [Data([0,1,2]), Data([0xFF,0x00,0xFF]), Data(repeating: 65, count: SourceTextDocument.maximumBytes + 1)] {
            try data.write(to: file)
            #expect(throws: (any Error).self) { try SourceTextDocument.load(file, at: .init(line: 1)) }
        }
        #expect(throws: (any Error).self) { try SourceTextDocument.load(temp, at: .init(line: 1)) }
        #expect(throws: (any Error).self) { try SourceTextDocument.load(temp.appendingPathComponent("missing"), at: .init(line: 1)) }
    }

    @Test func correctedSafetyHeadingLinkMatchesCanonicalAnchor() throws {
        let document = "[AI使用安全规则](#三ai-使用安全规则)\n\n# 三、AI 使用安全规则\n"
        let structure = try MarkdownStructure.parse(document)
        #expect(structure.anchors["三ai-使用安全规则"] == 1)
        #expect(structure.anchors["三ai使用安全规则"] == nil)
    }
}
