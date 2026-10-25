import Foundation
import Testing
@testable import LibraryCore

/// Measures what one full snapshot costs on a large library. Skipped unless
/// `PERSONAL_LIBRARY_BENCHMARK=1`, because it builds 10,000 rows first.
/// The same comparison is available to anyone without Xcode via
/// `./script/snapshot-benchmark.py`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PERSONAL_LIBRARY_BENCHMARK"] == "1"))
struct SnapshotPerformanceTests {
    static let documentCount = 10_000
    static let bodyCharacters = 20_000

    private static let oldColumns = """
        id, title, kind, relative_path, substr(body, 1, 240) AS preview,
               extraction_note, byte_count, created_at, updated_at, collection_id,
               favorite, image_base_path, deleted_at,
               length(trim(body)) > 0 AS has_body,
               instr(body, '](http') > 0 OR instr(body, '<http') > 0 AS has_links
        """

    private static let newColumns = """
        id, title, kind, relative_path, preview,
               extraction_note, byte_count, created_at, updated_at, collection_id,
               favorite, image_base_path, deleted_at, has_body, has_links
        """

    @Test func fullSnapshotIsWorthTheDerivedColumns() async throws {
        let root = testTemporaryDirectory.appendingPathComponent("snapshot-bench-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("library.sqlite")

        do {
            let database = try Database(url: path)
            let filler = String(repeating: "本合同由双方在平等自愿的基础上订立，任何一方不得擅自变更条款。",
                                count: Self.bodyCharacters / 32)
            try database.transaction {
                for index in 0..<Self.documentCount {
                    let body = "# 第 \(index) 份资料\n\n" + filler
                    try database.execute("""
                        INSERT INTO items (id, title, kind, relative_path, body, extraction_note,
                                           byte_count, created_at, updated_at, collection_id,
                                           favorite, fingerprint)
                        VALUES (?, ?, 'document', NULL, ?, NULL, ?, ?, ?, NULL, 0, ?)
                        """,
                        ["item-\(index)", "第 \(index) 份资料", body, "\(body.utf8.count)",
                         "\(1_700_000_000 + index)", "\(1_700_000_000 + index)", "fp-\(index)"])
                }
            }
            #expect(try database.rows("SELECT count(*) AS n FROM items").first?["n"] == "10000")
        }

        let repository = try LibraryRepository(root: root)
        // Warm the page cache once so the numbers describe repeated refreshes.
        _ = try await repository.snapshot()

        func measure(_ sql: String) throws -> (p50: Double, p95: Double) {
            let database = try Database(readOnly: path)
            var samples: [Double] = []
            for _ in 0..<7 {
                let started = Date()
                _ = try database.rows("SELECT \(sql) FROM items WHERE deleted_at IS NULL ORDER BY updated_at DESC, id")
                samples.append(Date().timeIntervalSince(started) * 1000)
            }
            samples.sort()
            return (samples[samples.count / 2], samples[Int(Double(samples.count) * 0.95)])
        }

        let before = try measure(Self.oldColumns)
        let after = try measure(Self.newColumns)
        let whole = Date()
        _ = try await repository.snapshot()
        let snapshotMilliseconds = Date().timeIntervalSince(whole) * 1000

        print("""
            snapshot benchmark: \(Self.documentCount) documents x \(Self.bodyCharacters) chars
              items query, body expressions : \(String(format: "%.1f", before.p50)) ms (p95 \(String(format: "%.1f", before.p95)))
              items query, stored columns   : \(String(format: "%.1f", after.p50)) ms (p95 \(String(format: "%.1f", after.p95)))
              whole snapshot()              : \(String(format: "%.1f", snapshotMilliseconds)) ms
            """)

        #expect(after.p50 < before.p50 / 3, "stored columns should cut the items query sharply")
        #expect(snapshotMilliseconds < 400)
    }
}
