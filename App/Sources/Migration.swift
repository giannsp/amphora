import Foundation

/// One-time carry-over from "IPSW Mirror", the name before Amphora.
enum Migration {
    private static let legacyDomain = "consulting.techne.ipswmirror"
    private static let legacyStore = "/Users/Shared/IPSW Mirror"
    private static let doneKey = "MigratedFromIPSWMirror"

    /// Copies settings the user chose. Skips first-launch bookkeeping, so the new app still registers
    /// its own login item and shows its own setup. Runs before AppModel reads any setting.
    static func runIfNeeded(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        guard let old = UserDefaults.standard.persistentDomain(forName: legacyDomain), !old.isEmpty else { return }

        let skipped: Set<String> = ["LoginItemOffered", "ConfiguratorSetupDismissed", "OnboardingCompleted"]
        for (key, value) in old where !skipped.contains(key) && !key.hasPrefix("NS") {
            if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }

        // Keep using the old download folder if it holds files: no 30 GB re-download.
        if defaults.string(forKey: "StorePath") == nil,
           let contents = try? FileManager.default.contentsOfDirectory(atPath: legacyStore),
           contents.contains(where: { $0.hasSuffix(".ipsw") }) {
            defaults.set(legacyStore, forKey: "StorePath")
        }
        // The setup assistant still opens once: it shows these values prefilled, so it's a quick confirm.
    }
}
