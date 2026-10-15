import Foundation
import XCTest
@testable import IPSWMirrorCore

final class SOFATests: XCTestCase {
    func testNewestSupportingMajorWins() throws {
        let feed = try JSONDecoder().decode(SOFAFeed.self, from: fixture("sofa"))
        let targets = feed.targetVersions()

        XCTAssertEqual(targets["iPhone16,1"], "27.0.1", "supported by 26 and 27 → 27")
        XCTAssertEqual(targets["iPhone12,1"], "27.0.1")
        XCTAssertEqual(targets["iPad11,1"], "26.7.1", "dropped by 27 → latest 26")
        XCTAssertEqual(targets["iPhone11,2"], "18.7.9")
        XCTAssertEqual(targets.count, 5, "a release without SupportedDevices adds nothing")
    }
}

final class IPSWMeTests: XCTestCase {
    func testSelectsSignedMatchingVersion() throws {
        let response = try JSONDecoder().decode(IPSWMeSource.DeviceResponse.self, from: fixture("ipswme-device"))
        let firmware = try XCTUnwrap(IPSWMeSource.select(response.firmwares, version: "27.0.1"))

        XCTAssertEqual(firmware.build, "24A446")
        XCTAssertEqual(firmware.fileName, "iPhone16,1_27.0.1_24A446_Restore.ipsw")
        XCTAssertEqual(firmware.size, 12_225_373_164)
        XCTAssertEqual(firmware.sha256, "7399c8d21f8526113e411434612457fba94e0d64a933f927605f7a043f6af9bb",
                       "checksums are normalised to lowercase")
    }

    func testLatestSignedPicksNewestSignedRelease() throws {
        let response = try JSONDecoder().decode(IPSWMeSource.DeviceResponse.self, from: fixture("ipswme-device"))
        XCTAssertEqual(IPSWMeSource.latestSigned(response.firmwares)?.version, "27.0.1")
        XCTAssertNil(IPSWMeSource.latestSigned(response.firmwares.filter { !$0.signed }),
                     "nothing signed means nothing to keep")
    }

    func testIgnoresUnsignedVersion() throws {
        let response = try JSONDecoder().decode(IPSWMeSource.DeviceResponse.self, from: fixture("ipswme-device"))
        XCTAssertNil(IPSWMeSource.select(response.firmwares, version: "27.0"))
    }
}

final class JamfTests: XCTestCase {
    func testInventoryCountsManagedPhonesAndPads() throws {
        let json = Data("""
        {"mobile_devices": [
          {"id": 1, "model_identifier": "iPhone16,1", "managed": true},
          {"id": 2, "model_identifier": "iPhone16,1", "managed": true},
          {"id": 3, "model_identifier": "iPad14,3", "managed": true},
          {"id": 4, "model_identifier": "iPhone12,1", "managed": false},
          {"id": 5, "model_identifier": "AppleTV14,1", "managed": true},
          {"id": 6, "managed": true}
        ]}
        """.utf8)
        let list = try JSONDecoder().decode(JamfClient.MobileDeviceList.self, from: json)

        let managed = JamfClient.inventory(from: list.mobileDevices, managedOnly: true)
        XCTAssertEqual(managed.counts, ["iPhone16,1": 2, "iPad14,3": 1])
        XCTAssertEqual(managed.deviceCount, 3)

        let all = JamfClient.inventory(from: list.mobileDevices, managedOnly: false)
        XCTAssertEqual(all.counts["iPhone12,1"], 1, "unmanaged devices count when asked")
    }

    func testURLNormalisation() throws {
        XCTAssertEqual(try JamfClient.normalizedURL("acme.jamfcloud.com/").absoluteString, "https://acme.jamfcloud.com")
        XCTAssertEqual(try JamfClient.normalizedURL(" https://jss.acme.eu:8443 ").absoluteString, "https://jss.acme.eu:8443")
        XCTAssertThrowsError(try JamfClient.normalizedURL("not a url"))
    }

    func testFormBodyEscapesReservedCharacters() {
        let body = String(decoding: JamfClient.formBody([("client_secret", "a+b&c=d e")]), as: UTF8.self)
        XCTAssertEqual(body, "client_secret=a%2Bb%26c%3Dd%20e")
    }
}

final class StoreTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPruneRemovesOnlyUnneededIPSWs() throws {
        for name in ["keep.ipsw", "old.ipsw", "stale.ipsw.part", "keep2.ipsw.part", "notes.txt"] {
            FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        let store = Store(root: root)

        let wouldRemove = try store.prune(keeping: ["keep.ipsw", "keep2.ipsw"], dryRun: true)
        XCTAssertEqual(Set(wouldRemove.map(\.lastPathComponent)), ["old.ipsw", "stale.ipsw.part"])
        XCTAssertEqual(store.ipswFiles().count, 4, "dry run deletes nothing")

        try store.prune(keeping: ["keep.ipsw", "keep2.ipsw"])
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        XCTAssertEqual(left, ["keep.ipsw", "keep2.ipsw.part", "notes.txt"])
    }

    func testDeleteRemovesFilePartialAndManifestEntry() throws {
        let store = Store(root: root)
        for name in ["a.ipsw", "a.ipsw.part", "b.ipsw"] {
            FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        try store.writeManifest(Manifest(entries: [
            .init(file: "a.ipsw", version: "27.0.1", build: "24A446", models: ["iPhone16,1"], sha256: nil),
            .init(file: "b.ipsw", version: "26.7.1", build: "23H6030", models: ["iPad11,1"], sha256: nil),
        ]))

        try store.delete(fileNamed: "a.ipsw")

        XCTAssertEqual(store.ipswFiles().map(\.lastPathComponent), ["b.ipsw"])
        XCTAssertEqual(store.readManifest().versionsByModel(), ["iPad11,1": "26.7.1"])
    }

    func testDeleteRefusesPathsAndOtherFiles() {
        let store = Store(root: root)
        XCTAssertThrowsError(try store.delete(fileNamed: "../escape.ipsw"))
        XCTAssertThrowsError(try store.delete(fileNamed: "notes.txt"))
    }

    func testManifestRoundTrip() throws {
        let store = Store(root: root)
        let manifest = Manifest(entries: [
            .init(file: "a.ipsw", version: "27.0.1", build: "24A446", models: ["iPhone16,1", "iPhone16,2"], sha256: nil),
        ])
        try store.writeManifest(manifest)

        let versions = store.readManifest().versionsByModel()
        XCTAssertEqual(versions, ["iPhone16,1": "27.0.1", "iPhone16,2": "27.0.1"])
    }
}

final class ChecksumTests: XCTestCase {
    func testSHA256() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(try Checksum.sha256(of: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}
