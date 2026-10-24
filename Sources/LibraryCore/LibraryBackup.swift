import CSQLite
import Foundation

/// One consistent copy of `library.sqlite`, produced with SQLite's own
/// `VACUUM INTO`. Copying the file with the file manager while the database is
/// open in WAL mode can capture a half-written state, which is the common way
/// to lose a library.
public struct LibraryBackup: Sendable, Equatable, Hashable, Identifiable {
    public var id: URL { url }
    public let url: URL
    public let date: Date
    public let byteCount: Int

    public var name: String { url.lastPathComponent }

    public init(url: URL, date: Date, byteCount: Int) {
        self.url = url
        self.date = date
        self.byteCount = byteCount
    }
}

/// What a backup file claims about itself once opened read-only.
public struct LibraryBackupContents: Sendable, Equatable {
    public let schemaVersion: Int
    public let itemCount: Int

    public init(schemaVersion: Int, itemCount: Int) {
        self.schemaVersion = schemaVersion
        self.itemCount = itemCount
    }
}

public enum LibraryBackupError: LocalizedError {
    case unreadable(String)
    case notALibrary
    case corrupt(String)
    case newerSchema(Int)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(message):
            "无法读取备份：\(message)"
        case .notALibrary:
            "这个文件不是个人资料库的备份。"
        case let .corrupt(report):
            "备份完整性检查未通过：\(report)"
        case let .newerSchema(version):
            "备份来自更新版本的 App（资料库版本 \(version)），请先升级 App 再恢复。"
        }
    }
}

/// Backups live beside the library so that copying the whole folder keeps them.
/// Nothing here opens the database for writing except `applyPendingRestore`,
/// which only moves files around before the library is opened.
public enum LibraryBackupStore {
    /// How many automatic backups to keep.
    public static let retention = 7
    public static let directoryName = "Backups"
    public static let databaseName = "library.sqlite"
    /// Written before a restore replaces the live database, so a bad backup can
    /// still be undone by hand.
    public static let safetyCopyName = "library-before-restore.sqlite"
    static let pendingName = "pending-restore.sqlite"

    public static func directory(in root: URL) -> URL {
        root.appendingPathComponent(directoryName, isDirectory: true)
    }

    @discardableResult
    public static func makeDirectory(in root: URL) throws -> URL {
        let directory = directory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func pendingRestore(in root: URL) -> URL? {
        let url = directory(in: root).appendingPathComponent(pendingName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `library-20261024-084731.sqlite`. Colons are path separators on APFS, so
    /// the timestamp uses dashes instead of the ISO 8601 form.
    public static func fileName(for date: Date) -> String {
        "library-\(stamp.string(from: date)).sqlite"
    }

    /// Newest first. Ignores the staged restore file and anything unreadable.
    public static func backups(in root: URL) throws -> [LibraryBackup] {
        let directory = directory(in: root)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names
            .filter { $0.hasPrefix("library-") && $0.hasSuffix(".sqlite") }
            .compactMap { name in
                let url = directory.appendingPathComponent(name)
                guard let date = date(from: name) else { return nil }
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
                return LibraryBackup(url: url, date: date, byteCount: size)
            }
            .sorted { $0.date > $1.date }
    }

    public static func newest(in root: URL) throws -> LibraryBackup? {
        try backups(in: root).first
    }

    /// Keeps the newest `keeping` backups and removes the rest.
    public static func prune(in root: URL, keeping: Int = retention) throws {
        for backup in try backups(in: root).dropFirst(max(keeping, 1)) {
            try FileManager.default.removeItem(at: backup.url)
        }
    }

    /// Checks a file without changing it: readable, not empty, `items` table
    /// present, `integrity_check` clean, schema version known.
    public static func inspect(_ url: URL) throws -> LibraryBackupContents {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "文件不可读"
            sqlite3_close(handle)
            throw LibraryBackupError.unreadable(message)
        }
        defer { sqlite3_close(handle) }

        guard let integrity = scalar(handle, "PRAGMA integrity_check"), integrity == "ok" else {
            throw LibraryBackupError.corrupt(scalar(handle, "PRAGMA integrity_check") ?? "未知错误")
        }
        guard scalar(handle, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'items'") == "1" else {
            throw LibraryBackupError.notALibrary
        }
        let version = Int(scalar(handle, "PRAGMA user_version") ?? "0") ?? 0
        guard version >= 1 else { throw LibraryBackupError.notALibrary }
        guard version <= supportedSchemaVersion else { throw LibraryBackupError.newerSchema(version) }
        let count = Int(scalar(handle, "SELECT COUNT(*) FROM items") ?? "0") ?? 0
        return LibraryBackupContents(schemaVersion: version, itemCount: count)
    }

    /// Validates `backup` first, then copies it into the library as a pending
    /// restore. The live database is untouched until the next launch.
    public static func stageRestore(from backup: URL, in root: URL) throws {
        _ = try inspect(backup)
        let directory = try makeDirectory(in: root)
        let pending = directory.appendingPathComponent(pendingName)
        let staged = directory.appendingPathComponent(pendingName + ".staged")
        let manager = FileManager.default
        if manager.fileExists(atPath: staged.path) { try manager.removeItem(at: staged) }
        try manager.copyItem(at: backup, to: staged)
        if manager.fileExists(atPath: pending.path) { try manager.removeItem(at: pending) }
        try manager.moveItem(at: staged, to: pending)
    }

    public static func cancelPendingRestore(in root: URL) throws {
        let pending = directory(in: root).appendingPathComponent(pendingName)
        if FileManager.default.fileExists(atPath: pending.path) { try FileManager.default.removeItem(at: pending) }
    }

    /// Runs before the database is opened. Returns `true` when a staged restore
    /// replaced the live library; the previous database is kept as
    /// `library-before-restore.sqlite`.
    @discardableResult
    public static func applyPendingRestore(in root: URL) throws -> Bool {
        let directory = directory(in: root)
        let pending = directory.appendingPathComponent(pendingName)
        let manager = FileManager.default
        guard manager.fileExists(atPath: pending.path) else { return false }
        // Never replace a working library with something that will not open.
        _ = try inspect(pending)

        let database = root.appendingPathComponent(databaseName)
        let safety = root.appendingPathComponent(safetyCopyName)
        let incoming = root.appendingPathComponent(databaseName + ".restoring")

        if manager.fileExists(atPath: incoming.path) { try manager.removeItem(at: incoming) }
        try manager.copyItem(at: pending, to: incoming)
        if manager.fileExists(atPath: database.path) {
            if manager.fileExists(atPath: safety.path) { try manager.removeItem(at: safety) }
            try manager.moveItem(at: database, to: safety)
            // A crash can leave committed rows in the WAL; keep it with the copy
            // so the previous database still opens.
            let wal = URL(fileURLWithPath: database.path + "-wal")
            let safetyWAL = URL(fileURLWithPath: safety.path + "-wal")
            if manager.fileExists(atPath: wal.path) {
                if manager.fileExists(atPath: safetyWAL.path) { try manager.removeItem(at: safetyWAL) }
                try manager.moveItem(at: wal, to: safetyWAL)
            }
        }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: database.path + suffix)
            if manager.fileExists(atPath: sidecar.path) { try manager.removeItem(at: sidecar) }
        }
        try manager.moveItem(at: incoming, to: database)
        try manager.removeItem(at: pending)
        return true
    }

    /// Highest `user_version` this build understands. A backup from a newer
    /// build is refused rather than restored into a database it cannot read.
    static var supportedSchemaVersion: Int { Database.schemaVersion }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static func date(from name: String) -> Date? {
        guard name.hasPrefix("library-"), name.hasSuffix(".sqlite") else { return nil }
        let start = name.index(name.startIndex, offsetBy: "library-".count)
        let end = name.index(name.endIndex, offsetBy: -".sqlite".count)
        return stamp.date(from: String(name[start..<end]))
    }

    private static func scalar(_ handle: OpaquePointer, _ sql: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
}
