import CryptoKit
import Foundation
import XCTest
@testable import AmphoraCore

/// Serves canned responses to a URLSession, so downloads and SOFA requests run without the network.
final class MockURLProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: ((URLRequest) -> Reply)?
    static var handler: ((URLRequest) -> Reply)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else { return }
        let reply = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In several pieces, like a real transfer.
        var offset = 0
        while offset < reply.body.count {
            let end = min(offset + 300_000, reply.body.count)
            client?.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class DownloadTests: XCTestCase {
    let body = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    var expected: String { SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() }
    var part: URL!

    override func setUp() {
        part = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ipsw.part")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: part)
        MockURLProtocol.handler = nil
    }

    /// Serves `body`, honouring a Range header unless `ignoreRange`.
    func serve(ignoreRange: Bool = false) {
        let body = body
        MockURLProtocol.handler = { request in
            if !ignoreRange, let range = request.value(forHTTPHeaderField: "Range"),
               let start = Int(range.dropFirst("bytes=".count).dropLast()) {
                return .init(status: 206, body: body.subdata(in: start..<body.count))
            }
            return .init(status: 200, body: body)
        }
    }

    func download() async throws -> Checksum.Digest {
        let digest = Checksum.Digest(.sha256, expected: expected)
        let downloader = FileDownloader(configuration: MockURLProtocol.configuration())
        try await downloader.download(URL(string: "https://updates.example/x.ipsw")!, to: part,
                                      expectedSize: Int64(body.count), digest: digest)
        return digest
    }

    func testFreshDownloadIsHashedAsItArrives() async throws {
        serve()
        let digest = try await download()
        XCTAssertEqual(try Data(contentsOf: part), body)
        XCTAssertEqual(digest.byteCount, Int64(body.count))
        XCTAssertTrue(digest.matches)
    }

    func testResumedDownloadHashesTheExistingPartFirst() async throws {
        try body.prefix(400_000).write(to: part)
        serve()
        let digest = try await download()
        XCTAssertEqual(try Data(contentsOf: part), body)
        XCTAssertEqual(digest.byteCount, Int64(body.count))
        XCTAssertTrue(digest.matches)
    }

    func testServerIgnoringTheResumeStartsTheHashOver() async throws {
        try Data(repeating: 0xFF, count: 400_000).write(to: part)   // stale bytes that must not count
        serve(ignoreRange: true)
        let digest = try await download()
        XCTAssertEqual(try Data(contentsOf: part), body)
        XCTAssertEqual(digest.byteCount, Int64(body.count))
        XCTAssertTrue(digest.matches)
    }

    func testCorruptDataDoesNotMatch() async throws {
        var bad = body
        bad[500_000] ^= 0xFF
        MockURLProtocol.handler = { _ in .init(status: 200, body: bad) }
        let digest = try await download()
        XCTAssertFalse(digest.matches)
    }
}

final class SOFAConditionalTests: XCTestCase {
    func testUnchangedFeedIsReusedFromTheSavedCopy() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache); MockURLProtocol.handler = nil }
        let feedData = try fixture("sofa")
        let client = SOFAClient(http: HTTPClient(session: URLSession(configuration: MockURLProtocol.configuration())),
                                cacheDirectory: cache)

        var sentETags: [String?] = []
        MockURLProtocol.handler = { request in
            let etag = request.value(forHTTPHeaderField: "If-None-Match")
            sentETags.append(etag)
            return etag == "W/\"v1\"" ? .init(status: 304) : .init(status: 200, headers: ["ETag": "W/\"v1\""], body: feedData)
        }

        let first = try await client.fetch()
        let second = try await client.fetch()   // answered with 304 and no body
        XCTAssertEqual(sentETags, [nil, "W/\"v1\""])
        XCTAssertEqual(second.targetVersions(), first.targetVersions())
        XCTAssertFalse(second.targetVersions().isEmpty)
    }
}

private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}
