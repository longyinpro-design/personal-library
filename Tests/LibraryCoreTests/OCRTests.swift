import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import LibraryCore

struct OCRTests {
    /// The recognizer needs the Vision text service. The CI workflow turns
    /// recognition off (`PERSONAL_LIBRARY_DISABLE_OCR`), and a host that
    /// sandboxes the service out of the process behaves the same way, so the
    /// tests below only run where recognition actually works.
    @Test(.enabled(if: !OCRText.isDisabled)) func pictureTextIsSearchableAfterImport() async throws {
        let root = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let picture = root.appendingPathComponent("公告.png")
        try write(picture) { try self.picture(text: "Notice 2026 September") }
        let repository = try LibraryRepository(root: root.appendingPathComponent("Library"))
        let report = try await repository.importFiles([picture])
        let id = try #require(report.importedIDs.first)

        let text = try await repository.body(for: id) ?? ""
        #expect(text.lowercased().contains("notice"))
        let item = try #require(try await repository.snapshot().items.first)
        #expect(item.extractionNote?.contains("视觉识别") == true)
        // The recognizer already ran, so the launch backfill has nothing left.
        #expect(try await repository.ocrPendingCount() == 0)
    }

    @Test(.enabled(if: !OCRText.isDisabled)) func pictureWithoutWordsStillImportsAndIsNotRetried() async throws {
        let root = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let picture = root.appendingPathComponent("空白.png")
        try write(picture) { try self.blankPicture() }
        let repository = try LibraryRepository(root: root.appendingPathComponent("Library"))
        let report = try await repository.importFiles([picture])
        let item = try #require(try await repository.snapshot().items.first)
        #expect(report.failures.isEmpty)
        #expect(try await repository.body(for: item.id) == "")
        #expect(item.extractionNote?.contains("没有识别到文字") == true)
        #expect(try await repository.ocrPendingCount() == 0)
        #expect(try await repository.backfillOCR() == 0)
    }

    @Test(.enabled(if: !OCRText.isDisabled)) func scannedPDFGetsTextFromTheRecognizer() async throws {
        let root = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("扫描件.pdf")
        try makeScannedPDF(pdf, text: "Invoice 4471")
        // The fixture really is a scan: PDFKit finds no text layer in it.
        let document = try #require(PDFDocument(url: pdf))
        #expect((document.page(at: 0)?.string ?? "").isEmpty)

        let repository = try LibraryRepository(root: root.appendingPathComponent("Library"))
        _ = try await repository.importFiles([pdf])
        let item = try #require(try await repository.snapshot().items.first)
        #expect((try await repository.body(for: item.id) ?? "").lowercased().contains("invoice"))
        #expect(item.extractionNote?.contains("扫描页") == true)
    }

    @Test(.enabled(if: !OCRText.isDisabled)) func backfillReadsPicturesImportedBeforeTheRecognizer() async throws {
        let root = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let picture = root.appendingPathComponent("旧图片.png")
        try write(picture) { try self.picture(text: "Archive 1998") }
        let library = root.appendingPathComponent("Library")
        let repository = try LibraryRepository(root: library)
        _ = try await repository.importFiles([picture])
        // Pretend the item was imported by an older build with no OCR column yet.
        let database = try Database(url: library.appendingPathComponent("library.sqlite"))
        try database.execute("UPDATE items SET ocr_version = 0, body = '', extraction_note = NULL")
        #expect(try await repository.ocrPendingCount() == 1)

        #expect(try await repository.backfillOCR() == 1)
        #expect(try await repository.ocrPendingCount() == 0)
        let id = try #require(try await repository.snapshot().items.first?.id)
        let text = try await repository.body(for: id) ?? ""
        #expect(text.lowercased().contains("archive"))
        // A second pass has nothing to do.
        #expect(try await repository.backfillOCR() == 0)
    }

    @Test func backfillMarksItemsWhoseFileIsGone() async throws {
        let root = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let picture = root.appendingPathComponent("丢失.png")
        try write(picture) { try self.blankPicture() }
        let library = root.appendingPathComponent("Library")
        let repository = try LibraryRepository(root: library)
        _ = try await repository.importFiles([picture])
        let database = try Database(url: library.appendingPathComponent("library.sqlite"))
        try database.execute("UPDATE items SET ocr_version = 0")
        try FileManager.default.removeItem(at: library.appendingPathComponent("Files").appendingPathComponent(
            try #require(database.rows("SELECT relative_path FROM items").first?["relative_path"] ?? nil)))

        #expect(try await repository.backfillOCR() == 0)
        #expect(try await repository.ocrPendingCount() == 0)
    }

    // MARK: 样本

    private func write(_ url: URL, _ make: () throws -> CGImage) throws {
        let image = try make()
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func context(width: Int, height: Int) throws -> CGContext {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    }

    private func blankPicture() throws -> CGImage {
        let context = try context(width: 400, height: 200)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        return try #require(context.makeImage())
    }

    private func picture(text: String) throws -> CGImage {
        let context = try context(width: 900, height: 240)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 240))
        draw(text, in: context, size: 72, at: CGPoint(x: 40, y: 90))
        return try #require(context.makeImage())
    }

    private func draw(_ text: String, in context: CGContext, size: CGFloat, at point: CGPoint) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    /// Builds a PDF whose page holds only pixels, which is what a scan looks like
    /// to PDFKit: the text is visible but there is no text layer to extract.
    private func makeScannedPDF(_ url: URL, text: String) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        let page = try context(width: 612, height: 792)
        page.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        page.fill(box)
        draw(text, in: page, size: 60, at: CGPoint(x: 60, y: 380))
        let image = try #require(page.makeImage())
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
    }
}
