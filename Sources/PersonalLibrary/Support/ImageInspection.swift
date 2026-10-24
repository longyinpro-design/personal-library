import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the viewer shows in its info panel. Kept separate from the view so the
/// parsing can be tested without a window.
struct ImageDetails: Equatable {
    let width: Int
    let height: Int
    let format: String
    let byteCount: Int64
    let capturedAt: Date?
    let camera: String?

    var pixelDescription: String { "\(width) × \(height)" }

    var byteDescription: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    var captureDescription: String? {
        guard let capturedAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: capturedAt)
    }
}

enum ImageInspection {
    /// Reads size, format, byte count and whatever EXIF the file carries.
    static func read(_ url: URL) -> ImageDetails? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { return nil }

        let type = CGImageSourceGetType(source).map { $0 as String }
        let format = type
            .flatMap { UTType($0)?.preferredFilenameExtension?.uppercased() }
            ?? url.pathExtension.uppercased()

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let capturedAt = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(parseExifDate)

        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let camera = [tiff?[kCGImagePropertyTIFFMake], tiff?[kCGImagePropertyTIFFModel]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return ImageDetails(width: width, height: height, format: format, byteCount: size,
                            capturedAt: capturedAt, camera: camera.isEmpty ? nil : camera)
    }

    /// EXIF writes local time as `yyyy:MM:dd HH:mm:ss` with no zone.
    static func parseExifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }
}
