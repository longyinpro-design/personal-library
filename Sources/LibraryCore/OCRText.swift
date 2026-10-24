import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// Reads text out of pictures and scanned pages with the on-device Vision
/// model. Everything here is local: no network, no language model download
/// beyond the ones macOS ships with.
enum OCRText {
    static let languages = ["zh-Hans", "en-US"]
    /// Vision takes a long time on very large frames while reading nothing
    /// extra, so images and pages are scaled down to this budget first.
    static let maximumPixels = 40_000_000
    static let maximumCharacters = 200_000
    static let thumbnailPixels = 3_000
    static let pageScale: CGFloat = 2

    /// Whether the on-device text service answers in this process. A sandboxed
    /// host can block it, so extraction checks first and falls back to filename
    /// search instead of failing the import.
    static let isAvailable: Bool = {
        guard let image = probeImage() else { return false }
        do {
            // Probe with the exact configuration real recognition uses: a host
            // may allow a cheaper level while blocking the accurate model.
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([makeRequest()])
            return true
        } catch { return false }
    }()

    private static func probeImage() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return context.makeImage()
    }

    /// Recognizes text in a picture on disk. Returns an empty string when the
    /// file cannot be decoded or holds no text; callers treat both the same.
    static func recognize(contentsOf url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return "" }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        return recognize(in: image)
    }

    /// Renders one PDF page and recognizes it. Used for pages that carry no
    /// text layer, which is what a scan looks like to PDFKit.
    static func recognize(pdfPage page: PDFPage) -> String {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width >= 1, bounds.height >= 1 else { return "" }
        var scale = pageScale
        if bounds.width * bounds.height * scale * scale > CGFloat(maximumPixels) {
            scale = (CGFloat(maximumPixels) / (bounds.width * bounds.height)).squareRoot()
        }
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return "" }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { return "" }
        return recognize(in: image)
    }

    private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        if supported.contains("zh-Hans") { request.recognitionLanguages = languages }
        return request
    }

    static func recognize(in image: CGImage) -> String {
        let request = makeRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return "" }
        // Vision reports boxes in a normalized space whose origin sits at the
        // bottom left, so a larger `maxY` means higher on the page.
        let observations = (request.results ?? []).sorted { lhs, rhs in
            if abs(lhs.boundingBox.maxY - rhs.boundingBox.maxY) > 0.01 {
                return lhs.boundingBox.maxY > rhs.boundingBox.maxY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return String(lines.joined(separator: "\n").prefix(maximumCharacters))
    }
}
