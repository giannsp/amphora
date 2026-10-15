import Foundation

/// Apple Configurator's firmware cache. An IPSW placed here is used for restores instead of downloading.
///
/// macOS protects this folder (it lives in Configurator's group container). Writing to it needs
/// Full Disk Access: granted by the user in System Settings, or by a Jamf PPPC profile
/// (SystemPolicyAllFiles) for managed Macs. Without it every write fails with "permission denied"
/// and macOS shows no prompt.
public enum ConfiguratorCache {
    public static var firmwareDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Firmware",
                                    isDirectory: true)
    }

    /// Opens Full Disk Access in System Settings.
    public static let fullDiskAccessSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    public enum Access: Equatable, Sendable {
        case granted
        /// Apple Configurator has never run on this Mac for this user.
        case configuratorNotFound
        /// macOS privacy protection blocks the folder: Full Disk Access is needed.
        case denied
    }

    /// Checks for real by creating the Firmware folder (harmless if it already exists).
    public static func checkAccess() -> Access {
        let fm = FileManager.default
        let container = firmwareDirectory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard fm.fileExists(atPath: container.path) else { return .configuratorNotFound }
        do {
            try fm.createDirectory(at: firmwareDirectory, withIntermediateDirectories: true)
            let probe = firmwareDirectory.appendingPathComponent(".amphora-\(UUID().uuidString)")
            try Data().write(to: probe)
            try fm.removeItem(at: probe)
            return .granted
        } catch {
            return .denied
        }
    }

    /// Copies a verified IPSW into the cache. On APFS the copy is a clone, so it costs no extra disk space
    /// as long as the store is on the same volume.
    public static func export(_ file: URL) throws {
        let fm = FileManager.default
        let destination = firmwareDirectory.appendingPathComponent(file.lastPathComponent)
        if fm.fileExists(atPath: destination.path) {
            if FileDownloader.size(of: destination) == FileDownloader.size(of: file) { return }
            try fm.removeItem(at: destination)
        }
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
