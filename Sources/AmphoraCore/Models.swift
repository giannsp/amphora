import Foundation

/// An iPhone, iPad or Mac model, identified the way Apple and Jamf identify it ("iPhone16,1", "Mac16,1").
public struct DeviceModel: Hashable, Sendable, Codable, Identifiable {
    public enum Family: String, Sendable, Codable, CaseIterable {
        case iPhone, iPad, mac
    }

    public let identifier: String
    public let name: String

    public var id: String { identifier }
    public var family: Family { Self.family(of: identifier) }

    public static func family(of identifier: String) -> Family {
        if identifier.hasPrefix("iPad") { return .iPad }
        if identifier.hasPrefix("iPhone") { return .iPhone }
        return .mac
    }

    /// Apple silicon Macs restore from an IPSW; Intel Macs can't. Every "MacN,N" identifier is Apple silicon
    /// (Apple switched to that scheme with the M1 Pro/Max generation); the first M1 models kept the old names.
    public static func isAppleSiliconMac(_ identifier: String) -> Bool {
        identifier.wholeMatch(of: #/Mac\d+,\d+|MacBookAir10,1|MacBookPro17,1|MacBookPro18,[1-4]|Macmini9,1|iMac21,[12]/#) != nil
    }

    /// Models Amphora can keep a restore file for: iPhones, iPads and Apple silicon Macs.
    public static func isRestorable(_ identifier: String) -> Bool {
        identifier.hasPrefix("iPhone") || identifier.hasPrefix("iPad") || isAppleSiliconMac(identifier)
    }

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
    public static let version = "0.3.0"
    public static let userAgent = "Amphora/\(version)"
}
