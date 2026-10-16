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

    /// A running checksum for one firmware, fed while the file downloads, so a 12 GB file doesn't have to
    /// be read back from disk to verify it. Nil when the source publishes no checksum.
    public static func digest(for firmware: Firmware) -> Digest? {
        if let expected = firmware.sha256 { return Digest(.sha256, expected: expected) }
        if let expected = firmware.sha1 { return Digest(.sha1, expected: expected) }
        return nil
    }

    /// Accumulates bytes in download order. Used from one queue at a time (the downloader's), so no locking.
    public final class Digest: @unchecked Sendable {
        public enum Algorithm: Sendable { case sha256, sha1 }

        public let algorithm: Algorithm
        public let expected: String
        private var sha256 = SHA256()
        private var sha1 = Insecure.SHA1()
        public private(set) var byteCount: Int64 = 0

        public init(_ algorithm: Algorithm, expected: String) {
            self.algorithm = algorithm
            self.expected = expected.lowercased()
        }

        public func update(_ data: Data) {
            switch algorithm {
            case .sha256: sha256.update(data: data)
            case .sha1: sha1.update(data: data)
            }
            byteCount += Int64(data.count)
        }

        /// Hashes what an earlier attempt already wrote, so a resumed download still verifies end to end.
        public func update(contentsOf url: URL) throws {
            try Checksum.stream(url) { update($0) }
        }

        /// Starts over, for when the server ignores a resume request and sends the whole file again.
        public func reset() {
            sha256 = SHA256()
            sha1 = Insecure.SHA1()
            byteCount = 0
        }

        public var matches: Bool {
            switch algorithm {
            case .sha256: return Checksum.hex(sha256.finalize()) == expected
            case .sha1: return Checksum.hex(sha1.finalize()) == expected
            }
        }
    }

    fileprivate static func stream(_ url: URL, _ consume: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: 8 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            consume(chunk)
        }
    }

    fileprivate static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
