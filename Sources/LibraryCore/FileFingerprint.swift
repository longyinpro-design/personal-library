import CryptoKit
import Foundation

/// SHA-256 of a file's bytes, read in chunks so a 200 MB import does not have to
/// be held in memory. The digest is what decides whether two imports are the same
/// document: names change, bytes do not.
public enum FileFingerprint {
    static let chunkSize = 1 << 20

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // `read(upToCount:)` is only non-nil-returning below EOF on macOS 10.15+,
            // but an empty read still has to end the loop.
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
