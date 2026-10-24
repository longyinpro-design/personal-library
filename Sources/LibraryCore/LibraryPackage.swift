import Foundation

public enum LibraryPackageError: LocalizedError {
    case missingItem
    case notAPackage
    case unsupportedVersion(Int)
    case destinationExists(String)
    case missingFile(String)
    case pathEscapesPackage(String)

    public var errorDescription: String? {
        switch self {
        case .missingItem: return "资料已不存在，可能已被删除。"
        case .notAPackage: return "这里没有可读取的资料包：缺少 metadata.json。"
        case let .unsupportedVersion(version): return "资料包版本 \(version) 比当前应用更新，请升级后再导入。"
        case let .destinationExists(name): return "「\(name)」已存在，请换一个位置或先改名。"
        case let .missingFile(name): return "资料包里缺少文件：\(name)"
        case let .pathEscapesPackage(name): return "资料包内的路径无效：\(name)"
        }
    }
}

/// A `.plib` is a plain directory: Markdown (or the original file), a JSON
/// sidecar and the referenced pictures. No SQLite, so Finder, git or any editor
/// can read it.
public enum LibraryPackage {
    public static let fileExtension = "plib"
    public static let metadataName = "metadata.json"
    public static let markdownName = "content.md"
    public static let attachmentsFolder = "attachments"
    public static let version = 1

    public struct Metadata: Codable, Sendable, Equatable {
        public var version: Int
        public var id: String
        public var title: String
        public var kind: String
        public var createdAt: Date
        public var updatedAt: Date
        public var tags: [String]
        public var originalPath: String?
        public var contentName: String
        public var attachments: [Attachment]

        public struct Attachment: Codable, Sendable, Equatable {
            public var reference: String
            public var file: String

            public init(reference: String, file: String) {
                self.reference = reference; self.file = file
            }
        }

        public init(version: Int = LibraryPackage.version, id: String, title: String, kind: String,
                    createdAt: Date, updatedAt: Date, tags: [String], originalPath: String?,
                    contentName: String, attachments: [Attachment]) {
            self.version = version; self.id = id; self.title = title; self.kind = kind
            self.createdAt = createdAt; self.updatedAt = updatedAt; self.tags = tags
            self.originalPath = originalPath; self.contentName = contentName
            self.attachments = attachments
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Keeps the folder name readable while dropping what a file system rejects.
    public static func packageName(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let trimmed = title.unicodeScalars.map { forbidden.contains($0) ? "_" : Character($0) }
            .prefix(80)
        let name = String(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名资料" : name
    }

    /// Accepts the package directory itself or anything inside it.
    static func packageDirectory(for url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if standardized.pathExtension == fileExtension { return standardized }
        if FileManager.default.fileExists(atPath: standardized.appendingPathComponent(metadataName).path) {
            return standardized
        }
        var parent = standardized.deletingLastPathComponent()
        if parent.pathExtension == fileExtension { return parent }
        // A file selected two levels deep still belongs to its package.
        for _ in 0..<2 {
            if FileManager.default.fileExists(atPath: parent.appendingPathComponent(metadataName).path) { return parent }
            parent = parent.deletingLastPathComponent()
        }
        return standardized
    }
}
