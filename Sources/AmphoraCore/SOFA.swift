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

    /// Where the last feed and its ETag are kept: ~/Library/Caches/consulting.techne.amphora.
    public static var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("consulting.techne.amphora", isDirectory: true)
    }

    let url: URL
    let http: HTTPClient
    let cacheDirectory: URL?

    public init(url: URL = SOFAClient.defaultURL, http: HTTPClient = HTTPClient(),
                cacheDirectory: URL? = SOFAClient.defaultCacheDirectory) {
        self.url = url
        self.http = http
        self.cacheDirectory = cacheDirectory
    }

    /// Always asks SOFA, never a cached response, so a release published minutes ago is seen.
    /// It sends the ETag of the copy it already has: when nothing changed, SOFA answers
    /// "304 Not Modified" with no body, and the saved copy is used.
    public func fetch() async throws -> SOFAFeed {
        let saved = savedFeed()
        var headers: [String: String] = [:]
        if let saved { headers["If-None-Match"] = saved.etag }

        let (data, response) = try await http.get(url, headers: headers)
        if response.statusCode == 304 {
            if let saved, let feed = try? JSONDecoder().decode(SOFAFeed.self, from: saved.body) { return feed }
            // Our copy is unreadable: ask again without the ETag.
            return try JSONDecoder().decode(SOFAFeed.self, from: try await http.get(url).0)
        }
        let feed = try JSONDecoder().decode(SOFAFeed.self, from: data)
        if let etag = response.value(forHTTPHeaderField: "ETag") { save(data, etag: etag) }
        return feed
    }

    private var bodyURL: URL? { cacheDirectory?.appendingPathComponent("ios_data_feed.json") }
    private var etagURL: URL? { cacheDirectory?.appendingPathComponent("ios_data_feed.etag") }

    private func savedFeed() -> (body: Data, etag: String)? {
        guard let bodyURL, let etagURL,
              let body = try? Data(contentsOf: bodyURL),
              let etag = try? String(contentsOf: etagURL, encoding: .utf8), !etag.isEmpty else { return nil }
        return (body, etag)
    }

    private func save(_ body: Data, etag: String) {
        guard let cacheDirectory, let bodyURL, let etagURL else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        // Body first: an ETag must never point at a body we don't have.
        try? FileManager.default.removeItem(at: etagURL)
        guard (try? body.write(to: bodyURL, options: .atomic)) != nil else { return }
        try? Data(etag.utf8).write(to: etagURL, options: .atomic)
    }
}
