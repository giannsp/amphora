import Foundation

/// Reads which iPhone, iPad and (optionally) Mac models an organization owns from Jamf Pro.
///
/// Auth: an API Client (Jamf Pro → Settings → API Roles and Clients) whose role has only
/// "Read Mobile Devices", plus "Read Computers" for Macs. The client-credentials token also works for the
/// Classic API, whose mobile device list returns every device's model identifier in one request; Macs come
/// from the Jamf Pro API's computer inventory, a page at a time.
public struct JamfClient: Sendable {
    public struct Credentials: Sendable, Equatable {
        public var url: URL
        public var clientID: String
        public var clientSecret: String

        public init(url: URL, clientID: String, clientSecret: String) {
            self.url = url
            self.clientID = clientID
            self.clientSecret = clientSecret
        }
    }

    /// Models and how many devices of each Jamf holds.
    public struct Inventory: Sendable, Equatable {
        public let counts: [String: Int]
        public let deviceCount: Int
        public let fetched: Date
        /// Things worth telling the user that didn't stop the inventory: a missing privilege for one kind
        /// of device, or Intel Macs that were skipped.
        public var notes: [String] = []
    }

    public enum JamfError: LocalizedError, Equatable {
        case invalidURL(String)
        case badCredentials
        case missingPrivilege(String)
        case unexpected(Int)
        case noDevices

        public var errorDescription: String? {
            switch self {
            case let .invalidURL(text):
                return "\"\(text)\" isn't a valid Jamf Pro address. Use something like https://yourorg.jamfcloud.com"
            case .badCredentials:
                return "Jamf Pro rejected the client ID or secret."
            case let .missingPrivilege(privilege):
                return "The API client's role needs the \"\(privilege)\" privilege."
            case let .unexpected(code):
                return "Jamf Pro answered with HTTP \(code)."
            case .noDevices:
                return "Jamf Pro returned no devices. Nothing was changed."
            }
        }
    }

    let credentials: Credentials
    let session: URLSession

    public init(credentials: Credentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    /// Accepts "yourorg.jamfcloud.com", "https://yourorg.jamfcloud.com/" or a URL with a port.
    public static func normalizedURL(_ text: String) throws -> URL {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed), let host = url.host, host.contains("."), url.query == nil else {
            throw JamfError.invalidURL(text)
        }
        return url
    }

    /// Model identifier → device count. Throws `.noDevices` rather than returning an empty
    /// inventory, so a misconfigured client can never make a sync delete everything.
    ///
    /// With `includeMacs`, Apple silicon Macs are counted too. A role missing one of the two privileges
    /// still yields the other kind of device, with a note, unless that leaves nothing at all.
    public func inventory(managedOnly: Bool = true, includeMacs: Bool = false) async throws -> Inventory {
        let token = try await accessToken()
        var counts: [String: Int] = [:]
        var total = 0
        var notes: [String] = []

        do {
            let mobile = Self.inventory(from: try await mobileDevices(token: token), managedOnly: managedOnly)
            counts.merge(mobile.counts, uniquingKeysWith: +)
            total += mobile.deviceCount
        } catch JamfError.missingPrivilege(let privilege) where includeMacs {
            notes.append("iPhones and iPads skipped: the API role needs \"\(privilege)\".")
        }

        if includeMacs {
            do {
                let macs = Self.macInventory(from: try await computers(token: token), managedOnly: managedOnly)
                counts.merge(macs.counts, uniquingKeysWith: +)
                total += macs.deviceCount
                if macs.intelSkipped > 0 {
                    notes.append("\(macs.intelSkipped) Intel \(macs.intelSkipped == 1 ? "Mac" : "Macs") skipped: "
                                 + "Intel Macs can't be restored from an IPSW.")
                }
            } catch JamfError.missingPrivilege(let privilege) {
                guard total > 0 else { throw JamfError.missingPrivilege(privilege) }
                notes.append("Macs skipped: add \"\(privilege)\" to the API role.")
            }
        }

        guard total > 0 else { throw JamfError.noDevices }
        return Inventory(counts: counts, deviceCount: total, fetched: Date(), notes: notes)
    }

    private func mobileDevices(token: String) async throws -> [MobileDevice] {
        let (data, response) = try await session.data(for: request("JSSResource/mobiledevices", token: token))
        try Self.check(response, privilege: "Read Mobile Devices")
        return try JSONDecoder().decode(MobileDeviceList.self, from: data).mobileDevices
    }

    /// Jamf Pro API computer inventory, only the sections needed, 500 at a time.
    private func computers(token: String) async throws -> [Computer] {
        var all: [Computer] = []
        var page = 0
        while page < 400 {   // 200,000 Macs: a safety stop, not a real limit
            var components = URLComponents(url: credentials.url.appendingPathComponent("api/v1/computers-inventory"),
                                           resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "section", value: "GENERAL"),
                URLQueryItem(name: "section", value: "HARDWARE"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page-size", value: "500"),
                URLQueryItem(name: "sort", value: "id:asc"),
            ]
            var pageRequest = request("", token: token)
            pageRequest.url = components.url
            let (data, response) = try await session.data(for: pageRequest)
            try Self.check(response, privilege: "Read Computers")
            let result = try JSONDecoder().decode(ComputerPage.self, from: data)
            all += result.results
            if result.results.isEmpty || all.count >= result.totalCount { break }
            page += 1
        }
        return all
    }

    private func request(_ path: String, token: String) -> URLRequest {
        var request = URLRequest(url: credentials.url.appendingPathComponent(path), timeoutInterval: 120)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    // MARK: Internals

    struct TokenResponse: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    struct MobileDeviceList: Decodable {
        let mobileDevices: [MobileDevice]
        enum CodingKeys: String, CodingKey { case mobileDevices = "mobile_devices" }
    }

    struct MobileDevice: Decodable {
        let modelIdentifier: String?
        let managed: Bool?
        enum CodingKeys: String, CodingKey {
            case modelIdentifier = "model_identifier"
            case managed
        }
    }

    struct ComputerPage: Decodable {
        let totalCount: Int
        let results: [Computer]
    }

    struct Computer: Decodable {
        struct General: Decodable {
            struct RemoteManagement: Decodable { let managed: Bool? }
            let remoteManagement: RemoteManagement?
        }
        struct Hardware: Decodable { let modelIdentifier: String? }
        let general: General?
        let hardware: Hardware?
    }

    static func macInventory(from computers: [Computer], managedOnly: Bool)
        -> (counts: [String: Int], deviceCount: Int, intelSkipped: Int) {
        var counts: [String: Int] = [:]
        var total = 0
        var intel = 0
        for computer in computers {
            if managedOnly && computer.general?.remoteManagement?.managed == false { continue }
            guard let id = computer.hardware?.modelIdentifier?.trimmingCharacters(in: .whitespaces), !id.isEmpty
            else { continue }
            guard DeviceModel.isAppleSiliconMac(id) else { intel += 1; continue }
            counts[id, default: 0] += 1
            total += 1
        }
        return (counts, total, intel)
    }

    static func inventory(from devices: [MobileDevice], managedOnly: Bool) -> Inventory {
        var counts: [String: Int] = [:]
        var total = 0
        for device in devices {
            if managedOnly && device.managed == false { continue }
            guard let id = device.modelIdentifier?.trimmingCharacters(in: .whitespaces),
                  id.hasPrefix("iPhone") || id.hasPrefix("iPad") else { continue }
            counts[id, default: 0] += 1
            total += 1
        }
        return Inventory(counts: counts, deviceCount: total, fetched: Date())
    }

    private func accessToken() async throws -> String {
        var request = URLRequest(url: credentials.url.appendingPathComponent("api/oauth/token"), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Self.formBody([
            ("grant_type", "client_credentials"),
            ("client_id", credentials.clientID),
            ("client_secret", credentials.clientSecret),
        ])

        let (data, response) = try await session.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status == 400 || status == 401 {
            throw JamfError.badCredentials
        }
        try Self.check(response)
        return try JSONDecoder().decode(TokenResponse.self, from: data).accessToken
    }

    /// application/x-www-form-urlencoded, escaping everything but unreserved characters,
    /// so secrets containing "&", "=" or "+" survive intact.
    static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return Data(fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
    }

    private static func check(_ response: URLResponse, privilege: String = "Read Mobile Devices") throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch status {
        case 200..<300: return
        case 401: throw JamfError.badCredentials
        case 403: throw JamfError.missingPrivilege(privilege)
        default: throw JamfError.unexpected(status)
        }
    }
}
