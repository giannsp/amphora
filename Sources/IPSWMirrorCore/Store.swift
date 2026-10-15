import Foundation

/// What is on disk and why. Written to `<store>/.state/manifest.json`.
public struct Manifest: Codable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public let file: String
        public let version: String
        public let build: String
        public let models: [String]
        public let sha256: String?
    }

    public var generated: Date
    public var entries: [Entry]
    /// Files this app placed in Apple Configurator's cache, so pruning never touches anything else there.
    public var exportedToConfigurator: [String]

    public init(generated: Date = Date(), entries: [Entry] = [], exportedToConfigurator: [String] = []) {
        self.generated = generated
        self.entries = entries
        self.exportedToConfigurator = exportedToConfigurator
    }

    /// Model identifier → version on disk.
    public func versionsByModel() -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries {
            for model in entry.models { result[model] = entry.version }
        }
        return result
    }
}

/// A dedicated folder of IPSWs. Anything ending in .ipsw that the current plan does not need gets pruned,
/// so it must not be shared with files you want to keep.
public struct Store: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var defaultRoot: URL {
        URL(fileURLWithPath: "/Users/Shared/IPSW Mirror", isDirectory: true)
    }

    var stateDirectory: URL { root.appendingPathComponent(".state", isDirectory: true) }
    var manifestURL: URL { stateDirectory.appendingPathComponent("manifest.json") }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    public func path(for firmware: Firmware) -> URL {
        root.appendingPathComponent(firmware.fileName)
    }

    public func partPath(for firmware: Firmware) -> URL {
        root.appendingPathComponent(firmware.fileName + ".part")
    }

    public func isComplete(_ firmware: Firmware) -> Bool {
        FileDownloader.size(of: path(for: firmware)) == firmware.size
    }

    public func availableCapacity() -> Int64 {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Every .ipsw and .ipsw.part file directly inside the store.
    public func ipswFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles])) ?? []
        return contents.filter { $0.lastPathComponent.hasSuffix(".ipsw") || $0.lastPathComponent.hasSuffix(".ipsw.part") }
    }

    /// Deletes every IPSW (or partial) whose base name is not in `keep`. Returns what was (or would be) removed.
    @discardableResult
    public func prune(keeping keep: Set<String>, dryRun: Bool = false) throws -> [URL] {
        var removed: [URL] = []
        for url in ipswFiles() {
            var name = url.lastPathComponent
            if name.hasSuffix(".part") { name.removeLast(5) }
            guard !keep.contains(name) else { continue }
            if !dryRun { try FileManager.default.removeItem(at: url) }
            removed.append(url)
        }
        return removed
    }

    /// Deletes one IPSW chosen by the user, any partial download of it, the copy this app placed in
    /// Apple Configurator's cache, and its manifest entry. Only plain `.ipsw` names inside the store are accepted.
    public func delete(fileNamed name: String) throws {
        guard name.hasSuffix(".ipsw"), !name.contains("/"), name != ".ipsw" else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        let fm = FileManager.default
        for url in [root.appendingPathComponent(name), root.appendingPathComponent(name + ".part")]
        where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        var manifest = readManifest()
        if manifest.exportedToConfigurator.contains(name) {
            ConfiguratorCache.prune(previouslyExported: [name], keeping: [])
            manifest.exportedToConfigurator.removeAll { $0 == name }
        }
        manifest.entries.removeAll { $0.file == name }
        try writeManifest(manifest)
    }

    public func readManifest() -> Manifest {
        guard let data = try? Data(contentsOf: manifestURL) else { return Manifest() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Manifest.self, from: data)) ?? Manifest()
    }

    public func writeManifest(_ manifest: Manifest) throws {
        try prepare()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }
}
