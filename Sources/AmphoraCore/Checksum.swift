import CryptoKit
import Foundation

public enum Checksum {
    public static func sha256(of url: URL) throws -> String {
        var hasher = SHA256()
        try stream(url) { hasher.update(data: $0) }
        return hex(hasher.finalize())
    }

    public static func sha1(of url: URL) throws -> String {
        var hasher = Insecure.SHA1()
        try stream(url) { hasher.update(data: $0) }
        return hex(hasher.finalize())
    }

    /// Prefers SHA-256; falls back to SHA-1 when that is all the source publishes.
    /// Returns false only when a published checksum does not match.
    public static func verify(_ url: URL, against firmware: Firmware) throws -> Bool {
        if let expected = firmware.sha256 { return try sha256(of: url) == expected }
        if let expected = firmware.sha1 { return try sha1(of: url) == expected }
        return true
    }

    private static func stream(_ url: URL, _ consume: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: 8 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            consume(chunk)
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
