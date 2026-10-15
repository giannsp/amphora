import Foundation

/// Where download URLs and checksums come from. SOFA says *which* version is current;
/// a firmware source says *where* that version's IPSW lives.
public protocol FirmwareSource: Sendable {
    /// The signed restore IPSW of `version` for one model, or nil if none is signed (yet).
    func signedFirmware(for identifier: String, version: String) async throws -> Firmware?
    /// Human-readable names for model identifiers.
    func devices() async throws -> [DeviceModel]
}

/// ipsw.me API v4 — a community service. Be polite: one request at a time, identified User-Agent.
public struct IPSWMeSource: FirmwareSource {
    static let base = URL(string: "https://api.ipsw.me/v4/")!

    struct DeviceResponse: Decodable {
        let firmwares: [Entry]
    }

    struct Entry: Decodable {
        let identifier: String
        let version: String
        let buildid: String
        let url: URL
        let sha256sum: String?
        let sha1sum: String?
        let filesize: Int64
        let signed: Bool
    }

    struct DeviceEntry: Decodable {
        let name: String
        let identifier: String
    }

    let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    public func signedFirmware(for identifier: String, version: String) async throws -> Firmware? {
        var components = URLComponents(url: Self.base.appendingPathComponent("device/\(identifier)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "type", value: "ipsw")]
        let response = try await http.getJSON(DeviceResponse.self, from: components.url!)
        return Self.select(response.firmwares, version: version)
    }

    public func devices() async throws -> [DeviceModel] {
        let all = try await http.getJSON([DeviceEntry].self, from: Self.base.appendingPathComponent("devices"))
        return all
            .filter { $0.identifier.hasPrefix("iPhone") || $0.identifier.hasPrefix("iPad") }
            .map { DeviceModel(identifier: $0.identifier, name: $0.name) }
    }

    /// Matches on version, not build: some models ship a different build than SOFA lists.
    static func select(_ entries: [Entry], version: String) -> Firmware? {
        guard let e = entries.first(where: { $0.version == version && $0.signed }) else { return nil }
        return Firmware(identifier: e.identifier, version: e.version, build: e.buildid, url: e.url,
                        sha256: e.sha256sum.flatMap { $0.isEmpty ? nil : $0.lowercased() },
                        sha1: e.sha1sum.flatMap { $0.isEmpty ? nil : $0.lowercased() },
                        size: e.filesize)
    }
}
