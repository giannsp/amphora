import Foundation

/// Reads which iPhone and iPad models an organization owns from Jamf Pro.
///
/// Auth: an API Client (Jamf Pro → Settings → API Roles and Clients) whose role has only
/// "Read Mobile Devices". The client-credentials token also works for the Classic API, whose
/// mobile device list returns every device's model identifier in one request.
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
    }

    public enum JamfError: LocalizedError, Equatable {
        case invalidURL(String)
        case badCredentials
        case missingPrivilege
        case unexpected(Int)
        case noDevices

        public var errorDescription: String? {
            switch self {
            case let .invalidURL(text):
                return "\"\(text)\" isn't a valid Jamf Pro address. Use something like https://yourorg.jamfcloud.com"
            case .badCredentials:
                return "Jamf Pro rejected the client ID or secret."
            case .missingPrivilege:
                return "The API client's role needs the \"Read Mobile Devices\" privilege."
            case let .unexpected(code):
                return "Jamf Pro answered with HTTP \(code)."
            case .noDevices:
                return "Jamf Pro returned no mobile devices. Nothing was changed."
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
    public func inventory(managedOnly: Bool = true) async throws -> Inventory {
        let token = try await accessToken()

        var request = URLRequest(url: credentials.url.appendingPathComponent("JSSResource/mobiledevices"), timeoutInterval: 120)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        let list = try JSONDecoder().decode(MobileDeviceList.self, from: data)
        let inventory = Self.inventory(from: list.mobileDevices, managedOnly: managedOnly)
        guard inventory.deviceCount > 0 else { throw JamfError.noDevices }
        return inventory
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

    private static func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch status {
        case 200..<300: return
        case 401: throw JamfError.badCredentials
        case 403: throw JamfError.missingPrivilege
        default: throw JamfError.unexpected(status)
        }
    }
}
