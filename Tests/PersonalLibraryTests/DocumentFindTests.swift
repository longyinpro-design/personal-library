import Foundation
import Testing
@testable import PersonalLibrary

@MainActor
struct DocumentFindTests {
    @Test func plainTextMatchesScrollToTheirChunk() {
        let text = (0..<12).map { "第 \($0) 段，提到计量协议。" }.joined(separator: "\n\n")
        let matches = DocumentFind.matches(in: text, query: "计量协议")
        #expect(matches.count == 12)
        #expect(matches.allSatisfy { $0.anchor == .bodyChunk(0) })
        #expect(matches.first?.snippet.contains("计量协议") == true)
    }

    @Test func longTextSpreadsMatchesAcrossChunks() {
        let filler = String(repeating: "无关正文。", count: 900)
        let text = "开头提到验收。\n" + filler + "\n结尾再次提到验收。"
        let matches = DocumentFind.matches(in: text, query: "验收")
        #expect(matches.count == 2)
        let anchors = matches.compactMap { match -> Int? in
            if case .bodyChunk(let index) = match.anchor { return index }
            return nil
        }
        #expect(anchors.count == 2)
        #expect(anchors[1] > anchors[0])
    }

    @Test func markdownMatchesReportSectionsInsteadOfChunks() {
        let sections = ["# 甲\n\n正文提到验收。", "## 乙\n\n再次提到验收。", "## 丙\n\n无关。"]
        let matches = DocumentFind.matches(in: "", query: "验收", markdownSections: sections)
        #expect(matches.map(\.anchor) == [.section(0), .section(1)])
        #expect(matches.allSatisfy { !$0.snippet.isEmpty })
    }

    @Test func searchIsCaseAndWidthInsensitiveAndSkipsEmptyQueries() {
        let text = "CSV 与 csv，还有 Ｃ Ｓ Ｖ。"
        #expect(DocumentFind.matches(in: text, query: "csv").count == 2)
        #expect(DocumentFind.matches(in: text, query: "  ").isEmpty)
        #expect(DocumentFind.matches(in: text, query: "找不到").isEmpty)
    }

    @Test func overlapsAreReportedAndCappedWithoutLooping() {
        let text = String(repeating: "aaa", count: 600)
        let matches = DocumentFind.matches(in: text, query: "aa")
        #expect(matches.count == DocumentFind.maximumMatches)
        #expect(matches.map(\.id) == Array(0..<DocumentFind.maximumMatches))
    }

    @Test func snippetStaysOnOneLineAndKeepsTheMatch() {
        let text = "前面的内容很长。\n\n验收标准写在这里，后面还有很多说明。\n\n后面的内容。"
        let snippet = DocumentFind.matches(in: text, query: "验收标准").first?.snippet ?? ""
        #expect(snippet.contains("验收标准"))
        #expect(!snippet.contains("\n"))
    }
}
