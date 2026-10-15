import Foundation

/// Apple Configurator's firmware cache. An IPSW placed here is used for restores instead of downloading.
///
/// UNVERIFIED: the path and the file naming Configurator expects still need a hands-on test
/// (see "Open questions" in the project spec). Export is therefore off by default.
public enum ConfiguratorCache {
    public static var firmwareDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Firmware",
                                    isDirectory: true)
    }

    /// Copies a verified IPSW into the cache. On APFS the copy is a clone, so it costs no extra disk space
    /// as long as the store is on the same volume.
    public static func export(_ file: URL) throws {
        let fm = FileManager.default
        let destination = firmwareDirectory.appendingPathComponent(file.lastPathComponent)
        guard !fm.fileExists(atPath: destination.path) else { return }
        try fm.createDirectory(at: firmwareDirectory, withIntermediateDirectories: true)
        try fm.copyItem(at: file, to: destination)
    }

    /// Removes files this app exported earlier and no longer needs. Never touches anything else.
    @discardableResult
    public static func prune(previouslyExported: [String], keeping keep: Set<String>, dryRun: Bool = false) -> [URL] {
        var removed: [URL] = []
        for name in previouslyExported where !keep.contains(name) {
            let url = firmwareDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if !dryRun { try? FileManager.default.removeItem(at: url) }
            removed.append(url)
        }
        return removed
    }
}
