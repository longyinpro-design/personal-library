import LibraryCore
import AppKit
import ImageIO
import MarkdownUI
import Testing
import UniformTypeIdentifiers
@testable import PersonalLibrary

struct MarkdownImageTests {
    @Test func archivedImagesDecodeAfterSourceMoveAndRepositoryReopen() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try png(source.appendingPathComponent("中文 图片.png"), red: 1)
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\"><rect width=\"40\" height=\"20\" fill=\"green\"/></svg>"
        try svg.write(to: source.appendingPathComponent("shape.svg"), atomically: true, encoding: .utf8)
        let text = "![PNG](中文%20图片.png)\n\nInline ![SVG](shape.svg) image."
        let file = source.appendingPathComponent("guide.md")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let library = root.appendingPathComponent("Library")
        let repo = try LibraryRepository(root: library)
        let report = try await repo.importFiles([file])
        #expect(report.importedIDs.count == 1 && report.warnings.isEmpty)
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("source-moved"))
        let reopened = try LibraryRepository(root: library)
        let item = try #require(try await reopened.snapshot().items.first)
        let context = MarkdownImageContext(itemID: item.id, basePath: item.imageBasePath, attachments: item.imageAttachments)
        let references = try MarkdownImageSource.references(in: text).urls
        let loader = LocalMarkdownImages()
        let raster = try await loader.load(references[0], context: context)
        let rasterPixel = try #require(NSBitmapImageRep(cgImage: raster).colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
        #expect(rasterPixel.redComponent > 0.9 && rasterPixel.blueComponent < 0.1)
        let vector = try await loader.load(references[1], context: context)
        #expect(vector.width == 40 && vector.height == 20)
        #expect((NSBitmapImageRep(cgImage: vector).colorAt(x: 2, y: 2)?.greenComponent ?? 0) > 0.4)
        _ = try await LocalInlineImageProvider(context: context).image(with: references[1], label: "SVG")
        try FileManager.default.removeItem(at: #require(item.imageAttachments[references[0].absoluteString]))
        await #expect(throws: (any Error).self) { try await loader.load(references[0], context: context) }
    }

    private func workspace() throws -> URL {
        let url = testTemporaryDirectory.appendingPathComponent("markdown-images-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func png(_ path: URL, red: CGFloat, width: Int = 16) throws {
        let context = try #require(CGContext(data: nil, width: width, height: 8, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: 1 - red, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 8))
        let destination = try #require(CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func pathsRespectSourceDirectoryAndLocalOnlyBoundary() throws {
        let base = URL(fileURLWithPath: "/tmp/资料/文档", isDirectory: true)
        let context = MarkdownImageContext(itemID: "one", basePath: base.path)
        for (input, expected) in [("images/%E4%B8%AD%E6%96%87%20%E5%9B%BE%E7%89%87.png", "/tmp/资料/文档/images/中文 图片.png"),
                                  ("../attachments/a.png", "/tmp/资料/attachments/a.png"),
                                  ("/tmp/a%20b.png", "/tmp/a b.png"), ("file:///tmp/a.png", "/tmp/a.png")] {
            let actual = try context.resolve(#require(URL(string: input)))
            let wanted = URL(fileURLWithPath: expected).standardizedFileURL.resolvingSymlinksInPath()
            #expect(actual == wanted, "Input: \(input), actual: \(actual), expected: \(wanted)")
        }
        for input in ["https://example.com/image.png", "http://127.0.0.1/a", "//host/share/a.png", "file://server/share/a.png", "data:image/png,test"] {
            #expect(throws: (any Error).self) { try context.resolve(#require(URL(string: input))) }
        }
        #expect(throws: (any Error).self) { try MarkdownImageContext(itemID: "note", basePath: nil).resolve(URL(string: "relative.png")!) }
        #expect(try MarkdownImageContext(itemID: "note", basePath: nil).resolve(URL(fileURLWithPath: "/tmp/a.png")).isFileURL)
    }

    @Test func mixedUnicodeAndEscapesStayDistinctAndPreserveMarkdownStructure() {
        let body = """
        ![空格](中文%20图片.png)

        ![百分号](%E4%B8%AD%E6%96%87%2520%E5%9B%BE%E7%89%87.png)

        - [x] 已完成

        | 名称 | 图 |
        | --- | --- |
        | 表格 | ![引用][image] |

        [image]: 中文%20图片.png

        ```text
        ![示例](中文%20图片.png)
        ```
        """
        let normalized = MarkdownImageSource.normalizingImageURLs(body)
        let html = MarkdownContent(normalized).renderHTML()
        #expect(html.contains("src=\"%E4%B8%AD%E6%96%87%20%E5%9B%BE%E7%89%87.png\""))
        #expect(html.contains("src=\"%E4%B8%AD%E6%96%87%2520%E5%9B%BE%E7%89%87.png\""))
        #expect(html.contains("<table>"))
        #expect(html.contains("type=\"checkbox\""))
        #expect(html.contains("![示例](中文%20图片.png)"))
    }

    @Test func handbookMarkersResolveWithoutRewritingCodeOrSource() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("menus/meters")
        let images = root.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let file = images.appendingPathComponent("中文.png")
        try png(file, red: 1)
        let marker = "/imgstart:中文.png:imgend/"
        let code = "```text\n\(marker)\n```\n\n`\(marker)`"
        let input = "\(marker)\n\n\(code)"
        let result = MarkdownImageSource.renderable(input)
        #expect(result.contains(code))
        #expect(result.hasPrefix("![手册配图](library-image:"))
        #expect(input.hasPrefix(marker))
        let encoded = try #require("中文.png".addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let url = try #require(URL(string: "library-image:" + encoded))
        #expect(try MarkdownImageContext(itemID: "guide", basePath: source.path).resolve(url) == file)
        #expect(MarkdownContent(result).renderHTML().contains("<img"))
    }

    @Test func rasterDecodeUsesEachDirectoryAndBoundsLargeImages() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try png(root.appendingPathComponent("same.png"), red: 1)
        try png(second.appendingPathComponent("same.png"), red: 0)
        try png(root.appendingPathComponent("large.png"), red: 1, width: 4096)
        let loader = LocalMarkdownImages()
        let url = URL(string: "same.png")!
        let first = try await loader.load(url, context: .init(itemID: "one", basePath: root.path))
        let other = try await loader.load(url, context: .init(itemID: "two", basePath: second.path))
        #expect(first.width == 16 && first.height == 8)
        #expect(first.dataProvider?.data != other.dataProvider?.data)
        let large = try await loader.load(URL(string: "large.png")!, context: .init(itemID: "one", basePath: root.path))
        #expect(large.width == 2048)
        let cached = try await loader.load(url, context: .init(itemID: "one", basePath: root.path))
        #expect(cached === first)
        try "not an image".write(to: root.appendingPathComponent("bad.png"), atomically: true, encoding: .utf8)
        for name in ["bad.png", "missing.png", "second"] {
            await #expect(throws: (any Error).self) { try await loader.load(URL(string: name)!, context: .init(itemID: "one", basePath: root.path)) }
        }
        // One missing inline attachment must not throw away its valid neighbours.
        _ = try await LocalInlineImageProvider(context: .init(itemID: "one", basePath: root.path)).image(with: URL(string: "missing.png")!, label: "missing")
    }

    @Test func svgRendersLocalShapesAndRejectsExternalOrDynamicContent() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let context = MarkdownImageContext(itemID: "svg", basePath: root.path)
        let loader = LocalMarkdownImages()
        let body = "<defs><linearGradient id=\"g\"><stop stop-color=\"red\"/></linearGradient></defs><rect width=\"40\" height=\"20\" fill=\"url(#g)\"/>"
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\">\(body)</svg>"
        try svg.write(to: root.appendingPathComponent("valid.svg"), atomically: true, encoding: .utf8)
        let image = try await loader.load(URL(string: "valid.svg")!, context: context)
        #expect(image.width == 40 && image.height == 20)
        let pixels = NSBitmapImageRep(cgImage: image)
        #expect((pixels.colorAt(x: 10, y: 10)?.alphaComponent ?? 0) > 0.9)
        let invalid = [
            "<image href=\"http://127.0.0.1/probe\"/>",
            "<use href=\"file:///tmp/external.svg#shape\"/>",
            "<style><![CDATA[rect { fill: url(http://127.0.0.1/probe) }]]></style>",
            "<style>rect { fill: url/**/(http://127.0.0.1/probe) }</style>",
            "<s:script xmlns:s=\"http://www.w3.org/2000/svg\">alert(1)</s:script>",
            "<feImage href=\"http://127.0.0.1/probe\"/>",
            "<set attributeName=\"href\" to=\"http://127.0.0.1/probe\"/>",
            "<g xml:base=\"http://127.0.0.1/\"><use href=\"#shape\"/></g>"
        ]
        for (index, content) in invalid.enumerated() {
            let path = root.appendingPathComponent("invalid-\(index).svg")
            try svg.replacingOccurrences(of: body, with: content).write(to: path, atomically: true, encoding: .utf8)
            await #expect(throws: (any Error).self) { try await loader.load(path, context: context) }
        }
    }
}
