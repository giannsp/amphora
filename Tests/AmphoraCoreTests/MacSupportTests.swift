import Foundation
import XCTest
@testable import AmphoraCore

final class MacModelTests: XCTestCase {
    func testAppleSiliconIdentifiers() {
        for id in ["Mac16,1", "Mac17,2", "Mac13,1", "MacBookAir10,1", "MacBookPro17,1", "MacBookPro18,3", "Macmini9,1", "iMac21,2"] {
            XCTAssertTrue(DeviceModel.isAppleSiliconMac(id), id)
            XCTAssertEqual(DeviceModel.family(of: id), .mac, id)
        }
        for id in ["MacBookPro16,1", "MacBookAir9,1", "iMac20,1", "Macmini8,1", "MacPro7,1", "iMacPro1,1", "VirtualMac2,1", "iPhone16,1"] {
            XCTAssertFalse(DeviceModel.isAppleSiliconMac(id), id)
        }
        XCTAssertEqual(DeviceModel.family(of: "iPad14,4"), .iPad)
        XCTAssertEqual(DeviceModel.family(of: "iPhone15,4"), .iPhone)
        XCTAssertEqual(DeviceModel.identifiers(in: "Mac16,1 MacBookPro18,3,iPhone16,1"), ["Mac16,1", "MacBookPro18,3", "iPhone16,1"])
    }

    func testMacOSFeedTargetsAppleSiliconOnly() throws {
        let feed = try JSONDecoder().decode(SOFAFeed.self, from: macFixture("macos-feed"))
        let targets = feed.targetVersions()
        XCTAssertEqual(targets["Mac16,1"], "27.0.1")
        XCTAssertEqual(targets["MacBookAir10,1"], "27.0.1")
        XCTAssertEqual(targets["Mac99,9"], "26.7.1", "a Mac dropped by the newest macOS stays on its last major")
        XCTAssertNil(targets["MacBookPro16,1"], "Intel Macs can't be restored from an IPSW")
        XCTAssertNil(targets["J614sAP"], "board IDs are not model identifiers")
        XCTAssertEqual(feed.modelNames()["Mac16,1"], "MacBook Pro (M4, 14-inch, Nov 2024)")
    }

    func testIOSFeedStillParses() throws {
        let feed = try JSONDecoder().decode(SOFAFeed.self, from: macFixture("sofa"))
        XCTAssertFalse(feed.targetVersions().isEmpty)
        XCTAssertNil(feed.models)
    }
}

final class JamfMacTests: XCTestCase {
    let computersJSON = Data("""
    {"totalCount": 5, "results": [
      {"id": "1", "general": {"remoteManagement": {"managed": true}}, "hardware": {"modelIdentifier": "Mac16,1"}},
      {"id": "2", "general": {"remoteManagement": {"managed": true}}, "hardware": {"modelIdentifier": "Mac16,1"}},
      {"id": "3", "general": {"remoteManagement": {"managed": true}}, "hardware": {"modelIdentifier": "MacBookAir10,1"}},
      {"id": "4", "general": {"remoteManagement": {"managed": true}}, "hardware": {"modelIdentifier": "MacBookPro16,1"}},
      {"id": "5", "general": {"remoteManagement": {"managed": false}}, "hardware": {"modelIdentifier": "Mac15,3"}}
    ]}
    """.utf8)
    let mobileJSON = Data(#"{"mobile_devices": [{"model_identifier": "iPhone15,4", "managed": true}]}"#.utf8)

    override func tearDown() { MockURLProtocol.handler = nil }

    func client() throws -> JamfClient {
        JamfClient(credentials: .init(url: try JamfClient.normalizedURL("acme.jamfcloud.com"), clientID: "id", clientSecret: "s"),
                   session: URLSession(configuration: MockURLProtocol.configuration()))
    }

    /// Token always works; each endpoint answers with the given status (200 serves the fixture).
    func serve(mobile: Int, computers: Int) {
        let mobileJSON = mobileJSON, computersJSON = computersJSON
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/api/oauth/token") {
                return .init(status: 200, body: Data(#"{"access_token": "t"}"#.utf8))
            }
            if path.hasSuffix("/JSSResource/mobiledevices") {
                return mobile == 200 ? .init(status: 200, body: mobileJSON) : .init(status: mobile)
            }
            if path.hasSuffix("/api/v1/computers-inventory") {
                return computers == 200 ? .init(status: 200, body: computersJSON) : .init(status: computers)
            }
            return .init(status: 404)
        }
    }

    func testCountsAppleSiliconMacsAndSkipsIntel() async throws {
        serve(mobile: 200, computers: 200)
        let inventory = try await client().inventory(managedOnly: true, includeMacs: true)
        XCTAssertEqual(inventory.counts, ["iPhone15,4": 1, "Mac16,1": 2, "MacBookAir10,1": 1])
        XCTAssertEqual(inventory.deviceCount, 4)
        XCTAssertEqual(inventory.notes.count, 1)
        XCTAssertTrue(inventory.notes[0].contains("1 Intel Mac"))
    }

    func testMacsAreLeftOutUnlessAskedFor() async throws {
        serve(mobile: 200, computers: 403)
        let inventory = try await client().inventory(managedOnly: true)
        XCTAssertEqual(inventory.counts, ["iPhone15,4": 1])
        XCTAssertTrue(inventory.notes.isEmpty)
    }

    func testMissingReadComputersKeepsMobileDevices() async throws {
        serve(mobile: 200, computers: 403)
        let inventory = try await client().inventory(managedOnly: true, includeMacs: true)
        XCTAssertEqual(inventory.counts, ["iPhone15,4": 1])
        XCTAssertTrue(inventory.notes.contains { $0.contains("Read Computers") })
    }

    func testMissingReadMobileDevicesKeepsMacs() async throws {
        serve(mobile: 403, computers: 200)
        let inventory = try await client().inventory(managedOnly: true, includeMacs: true)
        XCTAssertEqual(inventory.counts["Mac16,1"], 2)
        XCTAssertNil(inventory.counts["iPhone15,4"])
        XCTAssertTrue(inventory.notes.contains { $0.contains("Read Mobile Devices") })
    }

    func testBothPrivilegesMissingFails() async throws {
        serve(mobile: 403, computers: 403)
        do {
            _ = try await client().inventory(managedOnly: true, includeMacs: true)
            XCTFail("expected an error")
        } catch let error as JamfClient.JamfError {
            XCTAssertEqual(error, .missingPrivilege("Read Computers"))
        }
    }
}

private func macFixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}
