import Foundation

/// Minimal JSON-over-HTTPS client with a project User-Agent, so upstream services can see who is calling.
public struct HTTPClient: Sendable {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func getJSON<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { throw MirrorError.http(url, status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// A GET that always goes to the server (never the shared URL cache) and returns 304 to the caller,
    /// so it can send `If-None-Match` and reuse its own saved copy.
    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) || http.statusCode == 304 else {
            throw MirrorError.http(url, (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return (data, http)
    }
}
