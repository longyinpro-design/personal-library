import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PersonalLibrary

struct ImageInspectionTests {
    private func writeImage(_ name: String, width: Int, height: Int,
                            type: UTType, properties: [CFString: Any] = [:]) throws -> URL {
        let url = testTemporaryDirectory.appendingPathComponent("inspect-" + UUID().uuidString + "-" + name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw InspectionTestError.writeFailed
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw InspectionTestError.writeFailed }
        return url
    }

    enum InspectionTestError: Error { case writeFailed }

    @Test func readsSizeFormatAndByteCount() throws {
        let url = try writeImage("plain.png", width: 640, height: 320, type: .png)
        defer { try? FileManager.default.removeItem(at: url) }

        let details = try #require(ImageInspection.read(url))
        #expect(details.width == 640)
        #expect(details.height == 320)
        #expect(details.format == "PNG")
        #expect(details.byteCount > 0)
        #expect(details.pixelDescription == "640 × 320")
    }

    @Test func readsTheExifCaptureDate() throws {
        let original = "2024:05:06 07:08:09"
        let url = try writeImage("dated.jpg", width: 64, height: 64, type: .jpeg,
                                 properties: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: original]])
        defer { try? FileManager.default.removeItem(at: url) }

        let details = try #require(ImageInspection.read(url))
        let captured = try #require(details.capturedAt)
        var components = Calendar(identifier: .gregorian).dateComponents(in: .current, from: captured)
        components.timeZone = nil
        #expect(components.year == 2024)
        #expect(components.month == 5)
        #expect(components.day == 6)
        #expect(components.hour == 7)
        #expect(details.format == "JPEG" || details.format == "JPG")
    }

    @Test func exifDateParsingRejectsWhatItCannotRead() {
        #expect(ImageInspection.parseExifDate("2024:05:06 07:08:09") != nil)
        #expect(ImageInspection.parseExifDate("not a date") == nil)
        #expect(ImageInspection.parseExifDate("") == nil)
    }

    @Test func missingOrBrokenFilesReturnNothing() throws {
        let missing = testTemporaryDirectory.appendingPathComponent("nope-" + UUID().uuidString + ".png")
        #expect(ImageInspection.read(missing) == nil)

        let broken = testTemporaryDirectory.appendingPathComponent("broken-" + UUID().uuidString + ".png")
        try Data("not an image".utf8).write(to: broken)
        defer { try? FileManager.default.removeItem(at: broken) }
        #expect(ImageInspection.read(broken) == nil)
    }
}
