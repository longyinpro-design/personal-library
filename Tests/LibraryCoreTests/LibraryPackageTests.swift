import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LibraryCore

@Suite(.serialized)
struct LibraryPackageTests {
    private func makeRoot(_ name: String) throws -> URL {
        let root = testTemporaryDirectory.appendingPathComponent("package-\(name)-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writePicture(width: Int = 40, height: Int = 24, at url: URL) throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func markdownRoundTripsWithPicturesTagsAndTimestamps() async throws {
        let root = try makeRoot("round-trip")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try writePicture(at: source.appendingPathComponent("diagram.png"))
        let markdown = source.appendingPathComponent("发布流程.md")
        try "# 发布流程\n\n第一步看图。\n\n![流程图](diagram.png)\n".write(to: markdown, atomically: true, encoding: .utf8)

        let original = try LibraryRepository(root: root.appendingPathComponent("library"))
        let report = try await original.importFiles([markdown])
        let id = try #require(report.importedIDs.first)
        try await original.addTags(["发布", "流程"], to: [id])
        let before = try #require(try await original.snapshot().items.first { $0.id == id })
        #expect(before.imageAttachments.count == 1)

        let exported = try await original.exportPackage(id: id, to: root)
        #expect(exported.pathExtension == "plib")
        #expect(FileManager.default.fileExists(atPath: exported.appendingPathComponent("metadata.json").path))
        #expect(FileManager.default.fileExists(atPath: exported.appendingPathComponent("content.md").path))
        let attachmentFiles = try FileManager.default.contentsOfDirectory(atPath: exported.appendingPathComponent("attachments").path)
        #expect(attachmentFiles.count == 1)

        let copy = try LibraryRepository(root: root.appendingPathComponent("other-library"))
        let imported = try await copy.importPackage(from: exported)
        #expect(imported.title == "发布流程.md")
        #expect(Set(imported.tags) == ["发布", "流程"])
        #expect(abs(imported.createdAt.timeIntervalSince(before.createdAt)) < 1)
        #expect(abs(imported.updatedAt.timeIntervalSince(before.updatedAt)) < 1)
        #expect(imported.imageAttachments.count == 1)
        let picture = try #require(imported.imageAttachments.values.first)
        #expect(FileManager.default.fileExists(atPath: picture.path))
        let body = try await copy.body(for: imported.id) ?? ""
        #expect(body.contains("第一步看图。"))
        #expect(body.contains("diagram.png"))
        let tagCount = try await copy.snapshot().tags.first { $0.name == "流程" }?.count
        #expect(tagCount == 1)
    }

    @Test func picturesComeFromThePackageAfterTheOriginalIsGone() async throws {
        let root = try makeRoot("detached")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try writePicture(at: source.appendingPathComponent("a.png"))
        let markdown = source.appendingPathComponent("手册.md")
        try "# 手册\n\n![图](a.png)\n".write(to: markdown, atomically: true, encoding: .utf8)

        let original = try LibraryRepository(root: root.appendingPathComponent("library"))
        let report = try await original.importFiles([markdown])
        let id = try #require(report.importedIDs.first)
        let exported = try await original.exportPackage(id: id, to: root)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: root.appendingPathComponent("library"))

        let copy = try LibraryRepository(root: root.appendingPathComponent("fresh"))
        let imported = try await copy.importPackage(from: exported)
        let picture = try #require(imported.imageAttachments.values.first)
        #expect(FileManager.default.fileExists(atPath: picture.path))
        #expect(picture.lastPathComponent.hasSuffix(".image"))
    }

    @Test func otherFormatsTravelAsOriginalBytes() async throws {
        let root = try makeRoot("text")
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("note.txt")
        try "会议纪要\n第二行\n".write(to: notes, atomically: true, encoding: .utf8)
        let original = try LibraryRepository(root: root.appendingPathComponent("library"))
        let report = try await original.importFiles([notes])
        let id = try #require(report.importedIDs.first)

        let exported = try await original.exportPackage(id: id, to: root)
        let content = exported.appendingPathComponent("content.txt")
        #expect(FileManager.default.fileExists(atPath: content.path))
        #expect(try String(contentsOf: content, encoding: .utf8) == "会议纪要\n第二行\n")

        let copy = try LibraryRepository(root: root.appendingPathComponent("other"))
        let imported = try await copy.importPackage(from: exported)
        #expect(imported.kind == .document)
        let body = try await copy.body(for: imported.id) ?? ""
        #expect(body.contains("会议纪要"))
    }

    @Test func exportingTwiceToTheSamePlaceIsRefusedAndLeavesNothingBehind() async throws {
        let root = try makeRoot("clash")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try LibraryRepository(root: root.appendingPathComponent("library"))
        let id = try await original.saveNote(title: "重名", body: "正文", kind: .note, collectionID: nil)
        let first = try await original.exportPackage(id: id, to: root)
        #expect(FileManager.default.fileExists(atPath: first.path))

        await #expect(throws: (any Error).self) { try await original.exportPackage(id: id, to: root) }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("plib-") }
        #expect(leftovers.isEmpty)
    }

    @Test func missingMetadataIsNotAPackage() async throws {
        let root = try makeRoot("empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("空包.plib", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let repository = try LibraryRepository(root: root.appendingPathComponent("library"))
        await #expect(throws: (any Error).self) { try await repository.importPackage(from: folder) }
    }

    @Test func failedExportLeavesNoHalfPackage() async throws {
        let root = try makeRoot("broken")
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("丢失.txt")
        try "内容\n".write(to: notes, atomically: true, encoding: .utf8)
        let library = root.appendingPathComponent("library")
        let repository = try LibraryRepository(root: library)
        let report = try await repository.importFiles([notes])
        let id = try #require(report.importedIDs.first)
        let relative = try #require(try await repository.snapshot().items.first?.relativePath)
        try FileManager.default.removeItem(at: library.appendingPathComponent("Files").appendingPathComponent(relative))

        await #expect(throws: (any Error).self) { try await repository.exportPackage(id: id, to: root) }
        let packages = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".plib") }
        #expect(packages.isEmpty)
    }

    @Test func packageNameKeepsReadableTitlesAndDropsSeparators() {
        #expect(LibraryPackage.packageName("合同 2026") == "合同 2026")
        #expect(LibraryPackage.packageName("a/b:c") == "a_b_c")
        #expect(LibraryPackage.packageName("   ") == "未命名资料")
    }
}
