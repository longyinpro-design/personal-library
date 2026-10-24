import Foundation
import PDFKit
import UniformTypeIdentifiers
import Darwin

struct ExtractedText {
    let kind: ItemKind
    let text: String
    let note: String?
    /// True when the text came out of the on-device recognizer, so the library
    /// knows not to OCR the item again on the next launch.
    var usedOCR = false
}

enum TextExtractor {
    static let maximumCharacters = 2_000_000
    /// Pages that carry no text layer are rendered and read; a huge scan is
    /// capped so one file cannot stall an import for minutes.
    static let maximumOCRedPages = 50
    /// A page whose text layer is shorter than this is treated as a scan.
    static let minimumPageCharacters = 8
    static let plainExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "toml", "xml", "html", "htm", "css", "js", "ts", "tsx", "jsx", "swift", "rs", "go", "py", "sh", "sql", "log", "ini", "conf"]

    static func extract(_ url: URL, temporaryDirectory: URL) -> ExtractedText {
        let ext = url.pathExtension.lowercased()
        if UTType(filenameExtension: ext)?.conforms(to: .image) == true {
            guard OCRText.isAvailable else {
                return .init(kind: .image, text: "", note: "此环境无法运行系统文字识别，可按文件名搜索。")
            }
            let text = OCRText.recognize(contentsOf: url)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return .init(kind: .image, text: "", note: "图片里没有识别到文字，可按文件名搜索。", usedOCR: true)
            }
            return .init(kind: .image, text: text, note: "正文由视觉识别生成（离线），图片本身请用预览查看。", usedOCR: true)
        }
        if ext == "pdf" {
            guard let pdf = PDFDocument(url: url), !pdf.isLocked else {
                return .init(kind: .document, text: "", note: "PDF 无法读取或已加密，可打开原文件查看。")
            }
            var text = ""
            var recognizedPages = 0
            var skippedPages = 0
            for index in 0..<pdf.pageCount {
                guard let page = pdf.page(at: index) else { continue }
                let layer = page.string ?? ""
                if layer.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumPageCharacters {
                    text += layer + "\n"
                } else if OCRText.isAvailable, recognizedPages < maximumOCRedPages {
                    recognizedPages += 1
                    let recognized = OCRText.recognize(pdfPage: page)
                    if !recognized.isEmpty { text += recognized + "\n" }
                } else {
                    skippedPages += 1
                }
                if text.count > maximumCharacters { return bounded(text, kind: .document, ocrPages: recognizedPages, skipped: skippedPages) }
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                let note = recognizedPages > 0
                    ? "未识别到文字，可按文件名搜索。"
                    : "未发现可提取文字，可按文件名搜索。"
                return .init(kind: .document, text: "", note: note, usedOCR: recognizedPages > 0)
            }
            return bounded(text, kind: .document, ocrPages: recognizedPages, skipped: skippedPages)
        }
        if ["docx", "doc", "rtf", "odt"].contains(ext) {
            do {
                let text = try officeText(url, temporaryDirectory: temporaryDirectory)
                return text.isEmpty ? .init(kind: .document, text: "", note: "文档未提取到文字，可打开原文件查看。") : bounded(text, kind: .document)
            } catch {
                return .init(kind: .document, text: "", note: "正文提取失败：\(error.localizedDescription)。仍可按文件名搜索并打开文件。")
            }
        }
        if plainExtensions.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .plainText) == true {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 8_000_004) ?? Data()
                var decoded = String(data: data, encoding: .utf8)
                // A bounded read may split the last UTF-8 scalar.
                if decoded == nil, data.count > 8_000_000 {
                    for trim in 1...3 where decoded == nil { decoded = String(data: data.dropLast(trim), encoding: .utf8) }
                }
                if decoded == nil, data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
                    decoded = String(data: data, encoding: .utf16)
                }
                guard let text = decoded else { throw LibraryError.message("当前支持 UTF-8 或带 BOM 的 UTF-16 文本") }
                return bounded(text, kind: ["txt", "md", "markdown"].contains(ext) ? .document : .other, truncated: data.count > 8_000_000)
            } catch {
                return .init(kind: .other, text: "", note: "正文提取失败：\(error.localizedDescription)")
            }
        }
        return .init(kind: .other, text: "", note: "此格式支持文件名搜索；可使用系统预览或打开原文件。")
    }

    private static func bounded(_ text: String, kind: ItemKind, truncated: Bool = false, ocrPages: Int = 0, skipped: Int = 0) -> ExtractedText {
        let limited = text.count > maximumCharacters || truncated
        var notes: [String] = []
        if ocrPages > 0 {
            notes.append("其中 \(ocrPages) 页为扫描页，已用视觉识别补出文字（离线）。")
            if skipped > 0 { notes.append("另有 \(skipped) 页未识别。") }
        }
        if limited { notes.append("内容较长，仅前 200 万个字符参与正文搜索。完整内容保留在文件中。") }
        return .init(
            kind: kind,
            text: String(text.prefix(maximumCharacters)),
            note: notes.isEmpty ? nil : notes.joined(separator: " "),
            usedOCR: ocrPages > 0)
    }

    private static func officeText(_ url: URL, temporaryDirectory: URL) throws -> String {
        let output = temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw LibraryError.message("无法创建提取临时文件") }
        defer { try? FileManager.default.removeItem(at: output) }
        let sink = try FileHandle(forWritingTo: output)
        defer { try? sink.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-encoding", "UTF-8", "-stdout", url.path]
        process.standardOutput = sink
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw LibraryError.message("提取超过 15 秒")
        }
        guard process.terminationStatus == 0 else { throw LibraryError.message("系统文档转换器无法读取此文件") }
        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: 8_000_004) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
