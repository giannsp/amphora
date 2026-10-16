import Foundation

/// The parts of the SOFA feeds this project uses: the iOS/iPadOS feed and the macOS feed.
/// Feeds: https://sofafeed.macadmins.io/v1/ios_data_feed.json and …/macos_data_feed.json, maintained by the
/// MacAdmins community. Both list each OS major's latest release; they differ in how models are listed.
public struct SOFAFeed: Decodable, Sendable {
    public struct OSVersion: Decodable, Sendable {
        /// "27" in the iOS feed, "Golden Gate 27" in the macOS feed.
        public let osVersion: String
        public let latest: Latest

        /// The OS major number, whichever way the feed spells it.
        public var major: Int? {
            osVersion.split(separator: " ").last.flatMap { Int($0) }
        }

        enum CodingKeys: String, CodingKey {
            case osVersion = "OSVersion"
            case latest = "Latest"
        }
    }

    public struct Latest: Decodable, Sendable {
        public let productVersion: String
        public let build: String?
        /// Model identifiers in the iOS feed; board IDs ("J314sAP") in the macOS feed, which lists models below.
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

    /// macOS feed only: each Mac model, its name and the OS majors it supports.
    public struct MacModel: Decodable, Sendable {
        public let marketingName: String?
        public let osVersions: [Int]

        enum CodingKeys: String, CodingKey {
            case marketingName = "MarketingName"
            case osVersions = "OSVersions"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            marketingName = try c.decodeIfPresent(String.self, forKey: .marketingName)
            osVersions = try c.decodeIfPresent([Int].self, forKey: .osVersions) ?? []
        }
    }

    public let updateHash: String?
    public let osVersions: [OSVersion]
    public let models: [String: MacModel]?

    enum CodingKeys: String, CodingKey {
        case updateHash = "UpdateHash"
        case osVersions = "OSVersions"
        case models = "Models"
    }

    /// Model identifier → latest version of the newest OS major that still supports it.
    /// A model dropped by iOS 27 but supported by iOS 26 maps to the latest 26.x.
    /// From the macOS feed, only Apple silicon Macs: Intel Macs can't be restored from an IPSW.
    public func targetVersions() -> [String: String] {
        var result: [String: String] = [:]
        let newestFirst = osVersions.sorted { ($0.major ?? 0) > ($1.major ?? 0) }
        for os in newestFirst {
            for model in os.latest.supportedDevices
            where result[model] == nil && model.wholeMatch(of: #/[A-Za-z]+\d+,\d+/#) != nil {
                result[model] = os.latest.productVersion
            }
        }
        let latestByMajor = Dictionary(newestFirst.compactMap { os in os.major.map { ($0, os.latest.productVersion) } },
                                       uniquingKeysWith: { first, _ in first })
        for (identifier, mac) in models ?? [:] where DeviceModel.isAppleSiliconMac(identifier) {
            if let major = mac.osVersions.filter({ latestByMajor[$0] != nil }).max() {
                result[identifier] = latestByMajor[major]
            }
        }
        return result
    }

    /// Marketing names the macOS feed gives its models ("MacBook Pro (14-inch, M5)").
    public func modelNames() -> [String: String] {
        (models ?? [:]).compactMapValues(\.marketingName)
    }
}

public struct SOFAClient: Sendable {
    public static let defaultURL = URL(string: "https://sofafeed.macadmins.io/v1/ios_data_feed.json")!
    public static let macOSURL = URL(string: "https://sofafeed.macadmins.io/v1/macos_data_feed.json")!

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

    /// One saved copy per feed, named after it ("ios_data_feed.json", "macos_data_feed.json").
    private var bodyURL: URL? { cacheDirectory?.appendingPathComponent(url.lastPathComponent) }
    private var etagURL: URL? {
        cacheDirectory?.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".etag")
    }

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
