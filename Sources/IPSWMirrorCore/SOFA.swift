import Foundation

/// The parts of the SOFA iOS/iPadOS feed this project uses.
/// Feed: https://sofafeed.macadmins.io/v1/ios_data_feed.json — maintained by the MacAdmins community.
public struct SOFAFeed: Decodable, Sendable {
    public struct OSVersion: Decodable, Sendable {
        public let osVersion: String
        public let latest: Latest

        enum CodingKeys: String, CodingKey {
            case osVersion = "OSVersion"
            case latest = "Latest"
        }
    }

    public struct Latest: Decodable, Sendable {
        public let productVersion: String
        public let build: String?
        public let supportedDevices: [String]

        enum CodingKeys: String, CodingKey {
            case productVersion = "ProductVersion"
            case build = "Build"
            case supportedDevices = "SupportedDevices"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            productVersion = try c.decode(String.self, forKey: .productVersion)
            build = try c.decodeIfPresent(String.self, forKey: .build)
            supportedDevices = try c.decodeIfPresent([String].self, forKey: .supportedDevices) ?? []
        }
    }

    public let updateHash: String?
    public let osVersions: [OSVersion]

    enum CodingKeys: String, CodingKey {
        case updateHash = "UpdateHash"
        case osVersions = "OSVersions"
    }

    /// Model identifier → latest version of the newest OS major that still supports it.
    /// A model dropped by iOS 27 but supported by iOS 26 maps to the latest 26.x.
    public func targetVersions() -> [String: String] {
        var result: [String: String] = [:]
        let newestFirst = osVersions.sorted { (Int($0.osVersion) ?? 0) > (Int($1.osVersion) ?? 0) }
        for os in newestFirst {
            for model in os.latest.supportedDevices where result[model] == nil {
                result[model] = os.latest.productVersion
            }
        }
        return result
    }
}

public struct SOFAClient: Sendable {
    public static let defaultURL = URL(string: "https://sofafeed.macadmins.io/v1/ios_data_feed.json")!

    let url: URL
    let http: HTTPClient

    public init(url: URL = SOFAClient.defaultURL, http: HTTPClient = HTTPClient()) {
        self.url = url
        self.http = http
    }

    public func fetch() async throws -> SOFAFeed {
        try await http.getJSON(SOFAFeed.self, from: url)
    }
}
