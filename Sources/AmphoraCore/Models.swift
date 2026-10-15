import Foundation

/// An iPhone or iPad model, identified the way Apple and Jamf identify it ("iPhone16,1").
public struct DeviceModel: Hashable, Sendable, Codable, Identifiable {
    public enum Family: String, Sendable, Codable, CaseIterable {
        case iPhone, iPad
    }

    public let identifier: String
    public let name: String

    public var id: String { identifier }
    public var family: Family { identifier.hasPrefix("iPad") ? .iPad : .iPhone }

    /// Model identifiers in free text. Identifiers contain a comma themselves ("iPhone16,1"), so a list like
    /// "iPhone16,1,iPad14,3" can't be split on commas; this finds each "<letters><n>,<n>" instead.
    /// Spaces, commas and newlines all work as separators. Duplicates are dropped, order is kept.
    public static func identifiers(in text: String) -> [String] {
        var seen = Set<String>()
        return text.matches(of: #/[A-Za-z]+\d+,\d+/#).map { String($0.output) }.filter { seen.insert($0).inserted }
    }

    public init(identifier: String, name: String) {
        self.identifier = identifier
        self.name = name
    }
}

/// One restore IPSW as published by Apple.
public struct Firmware: Hashable, Sendable, Codable {
    public let identifier: String
    public let version: String
    public let build: String
    public let url: URL
    public let sha256: String?
    public let sha1: String?
    public let size: Int64

    /// Apple's own file name. Several models often share one file.
    public var fileName: String { url.lastPathComponent }

    public init(identifier: String, version: String, build: String, url: URL,
                sha256: String?, sha1: String?, size: Int64) {
        self.identifier = identifier
        self.version = version
        self.build = build
        self.url = url
        self.sha256 = sha256
        self.sha1 = sha1
        self.size = size
    }
}

/// A file the engine wants on disk, and every model it serves.
public struct PlannedItem: Hashable, Sendable {
    public let firmware: Firmware
    public let models: [String]
    public let onDisk: Bool
}

public enum MirrorError: LocalizedError, Sendable {
    case http(URL, Int)
    case sizeMismatch(String, expected: Int64, actual: Int64)
    case checksumMismatch(String)
    case insufficientSpace(neededBytes: Int64, availableBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case let .http(url, code):
            return "HTTP \(code) from \(url.host ?? url.absoluteString)"
        case let .sizeMismatch(name, expected, actual):
            return "\(name): size \(actual) does not match expected \(expected)"
        case let .checksumMismatch(name):
            return "\(name): checksum does not match, file discarded"
        case let .insufficientSpace(needed, available):
            let f = ByteCountFormatter.string(fromByteCount:countStyle:)
            return "Not enough disk space: need \(f(needed, .file)), \(f(available, .file)) available"
        }
    }
}

public enum AppInfo {
    public static let version = "0.2.0"
    public static let userAgent = "Amphora/\(version)"
}
