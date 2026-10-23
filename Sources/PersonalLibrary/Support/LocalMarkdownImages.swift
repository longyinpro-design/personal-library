import LibraryCore
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor LocalMarkdownImages {
    static let shared = LocalMarkdownImages()
    static let maximumBytes = 32 * 1024 * 1024
    private let cache = NSCache<NSString, ImageBox>()

    init() {
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 64
    }

    func load(_ url: URL, context: MarkdownImageContext) throws -> CGImage {
        try Task.checkCancellation()
        let file = try context.resolve(url).standardizedFileURL.resolvingSymlinksInPath()
        let values: URLResourceValues
        do { values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) }
        catch { throw MarkdownImageError.message("无法读取图片：\(file.lastPathComponent)") }
        guard values.isRegularFile == true else { throw MarkdownImageError.message("图片地址不是普通文件") }
        guard let size = values.fileSize, size <= Self.maximumBytes else { throw MarkdownImageError.message("图片超过 32 MB") }
        let key = "\(file.path)|\(size)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count <= Self.maximumBytes else { throw MarkdownImageError.message("图片超过 32 MB") }
        let image: CGImage
        if file.pathExtension.lowercased() == "svg" {
            image = try Self.decodeSVG(data)
        } else {
            image = try Self.decodeRaster(data)
        }
        try Task.checkCancellation()
        cache.setObject(ImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    private static func decodeRaster(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source), UTType(identifier as String)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double else {
            throw MarkdownImageError.message("文件不是支持的图片，或图片已损坏")
        }
        try validateSize(width: width, height: height)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw MarkdownImageError.message("图片解码失败") }
        return image
    }

    private static func decodeSVG(_ data: Data) throws -> CGImage {
        guard data.count <= 2 * 1024 * 1024 else { throw MarkdownImageError.message("SVG 图片超过 2 MB") }
        try LocalSVGPolicy.validate(data)
        guard let vector = NSImage(data: data) else { throw MarkdownImageError.message("SVG 图片无法解析") }
        try validateSize(width: vector.size.width, height: vector.size.height)
        let ratio = min(1, 2048 / max(vector.size.width, vector.size.height))
        let width = max(1, Int((vector.size.width * ratio).rounded(.up)))
        let height = max(1, Int((vector.size.height * ratio).rounded(.up)))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw MarkdownImageError.message("SVG 图片解码失败") }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        vector.draw(in: CGRect(x: 0, y: 0, width: width, height: height), from: .zero,
                    operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        guard let image = bitmap.cgImage else { throw MarkdownImageError.message("SVG 图片解码失败") }
        return image
    }

    private static func validateSize(width: Double, height: Double) throws {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 100_000, height <= 100_000, width * height <= 100_000_000 else {
            throw MarkdownImageError.message("图片尺寸超过可显示范围")
        }
    }
}

private final class ImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// A local SVG must remain self-contained before handing it to the native renderer.
private final class LocalSVGPolicy: NSObject, XMLParserDelegate {
    private var rejected = false
    private var rootSeen = false
    private var elements = 0
    private var inStyle = false
    private var style = ""

    static func validate(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8),
              text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
            throw MarkdownImageError.message("SVG 必须为不含外部实体的 UTF-8 图片")
        }
        let policy = LocalSVGPolicy()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = policy
        guard parser.parse(), policy.rootSeen, !policy.rejected else {
            throw MarkdownImageError.message("SVG 包含外部资源、动态内容或无效结构")
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        elements += 1
        let name = Self.localName(elementName)
        if !rootSeen { rootSeen = name == "svg"; if !rootSeen { reject(parser); return } }
        if elements > 10_000 || ["script", "foreignobject", "image", "feimage", "animate", "animatemotion", "animatetransform", "set"].contains(name) { reject(parser); return }
        for (key, value) in attributes {
            let key = Self.localName(key)
            if key.hasPrefix("on") || (key == "href" && !value.hasPrefix("#")) || key == "base" || !Self.safeStyle(value) {
                reject(parser); return
            }
        }
        if name == "style" { inStyle = true; style = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if inStyle { style += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if inStyle { style += String(decoding: CDATABlock, as: UTF8.self) }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if Self.localName(elementName) == "style" {
            if !Self.safeStyle(style) { reject(parser) }
            inStyle = false
        }
    }
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { reject(parser) }
    private func reject(_ parser: XMLParser) { rejected = true; parser.abortParsing() }
    private static func localName(_ name: String) -> String { String(name.split(separator: ":").last ?? "").lowercased() }

    private static func safeStyle(_ value: String) -> Bool {
        guard !value.contains("\\"), !value.contains("@"), !value.contains("/*") else { return false }
        let expression = try! NSRegularExpression(pattern: "(?i)url\\s*\\(([^)]*)\\)")
        return expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).allSatisfy { match in
            guard let range = Range(match.range(at: 1), in: value) else { return false }
            return value[range].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))).hasPrefix("#")
        }
    }
}
