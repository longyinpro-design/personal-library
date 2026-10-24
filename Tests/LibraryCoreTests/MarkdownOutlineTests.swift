import Foundation
import Testing
@testable import LibraryCore

struct MarkdownOutlineTests {
    @Test func headingsKeepTheirLevelsOrderAndSectionIndices() throws {
        let source = """
        # 总览

        第一段。

        ## 数据来源

        第二段。

        ### 计量协议

        第三段。

        ## 数据来源

        重复标题。
        """
        let outline = try MarkdownStructure.parse(source).headings
        #expect(outline.map(\.title) == ["总览", "数据来源", "计量协议", "数据来源"])
        #expect(outline.map(\.level) == [1, 2, 3, 2])
        #expect(outline.map(\.anchor) == ["总览", "数据来源", "计量协议", "数据来源-1"])
        // Each heading starts its own lazy section, in document order.
        #expect(outline.map(\.section) == outline.map(\.section).sorted())
        #expect(Set(outline.map(\.section)).count == outline.count)
    }

    @Test func nestedHeadingStaysInsideItsContainerSection() throws {
        let outline = try MarkdownStructure.parse("""
        - 列表项

          #### 列表里的标题

        正文。
        """).headings
        #expect(outline.count == 1)
        #expect(outline.first?.level == 4)
        #expect(outline.first?.section == 0)
    }

    @Test func anchorsStillResolveToTheSectionOfTheHeading() throws {
        let structure = try MarkdownStructure.parse("# 甲\n\n正文。\n\n## 乙\n\n更多。")
        #expect(structure.anchors["甲"] == structure.headings[0].section)
        #expect(structure.anchors["乙"] == structure.headings[1].section)
        #expect(structure.headings[1].section > structure.headings[0].section)
    }

    @Test func documentsWithoutHeadingsHaveNoOutline() throws {
        #expect(try MarkdownStructure.parse("只有正文。").headings.isEmpty)
    }
}
