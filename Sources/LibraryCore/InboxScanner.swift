import Foundation

/// Rules for a watched folder ("收件箱"). Kept free of file-system watching so
/// the decisions can be tested without waiting for events: given what the
/// folder holds and what was already imported, it says what is worth reading.
public enum InboxScanner {
    /// A file changed less than this many seconds ago may still be copying in,
    /// so it is left for the next pass instead of importing half a file.
    public static let settleInterval: TimeInterval = 1
    /// How many processed names are remembered before the oldest are dropped.
    public static let rememberedFiles = 500

    public struct Candidate: Sendable, Equatable {
        public let url: URL
        /// Size and modification time. A changed file gets a new signature and
        /// is retried; an unchanged one keeps matching and is skipped.
        public let signature: String

        public init(url: URL, signature: String) {
            self.url = url
            self.signature = signature
        }
    }

    public static func signature(of url: URL) -> String? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              let size = values.fileSize,
              let modified = values.contentModificationDate else { return nil }
        return "\(size)|\(Int(modified.timeIntervalSince1970))"
    }

    /// Files worth importing right now, oldest first so a batch keeps the order
    /// the user created it in.
    public static func candidates(in folder: URL, processed: [String: String], now: Date = Date()) -> [Candidate] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var found: [(date: Date, candidate: Candidate)] = []
        for url in entries {
            // Hidden files are skipped by the enumeration options, but a dot file
            // can still slip in through unusual volumes; check the name too.
            guard !url.lastPathComponent.hasPrefix(".") else { continue }
            guard let signature = signature(of: url) else { continue }
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) >= settleInterval else { continue }
            guard processed[url.lastPathComponent] != signature else { continue }
            found.append((modified, Candidate(url: url, signature: signature)))
        }
        return found.sorted { $0.date < $1.date }.map(\.candidate)
    }
}

/// What a library remembers about its inbox: the signature each file had when
/// it was last handled, plus the last failure worth showing in settings.
public struct InboxState: Codable, Sendable, Equatable {
    public static let fileName = "inbox.json"

    public var processed: [String: String]
    public var lastError: String?
    /// Bookmark of the watched folder, so the library remembers it across
    /// launches without a process-wide preference.
    public var folderBookmark: Data?

    public init(processed: [String: String] = [:], lastError: String? = nil, folderBookmark: Data? = nil) {
        self.processed = processed
        self.lastError = lastError
        self.folderBookmark = folderBookmark
    }

    public static func load(from root: URL) -> InboxState {
        let url = root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(InboxState.self, from: data) else { return InboxState() }
        return state
    }

    public func save(in root: URL) {
        let url = root.appendingPathComponent(InboxState.fileName)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Remembers one file, dropping the oldest entries once the list grows.
    public mutating func mark(_ name: String, signature: String) {
        processed[name] = signature
        guard processed.count > InboxScanner.rememberedFiles else { return }
        // Dictionary order is not insertion order; keep a bounded set instead by
        // dropping names that no longer exist once the cap is hit.
        let excess = processed.count - InboxScanner.rememberedFiles
        for key in processed.keys.prefix(excess) { processed[key] = nil }
    }
}
