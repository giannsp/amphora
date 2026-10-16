import AmphoraCore
import AppKit
import UserNotifications

/// Tells the user when new restore files are ready, or when downloads failed.
/// macOS only shows these while Amphora isn't the frontmost app, so a sync you're watching stays quiet.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Opens the main window when a notification is clicked. Set by the UI once it exists.
    var openMainWindow: (() -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    func install() {
        center.delegate = self
    }

    /// Asks once; macOS remembers the answer. Returns whether notifications are allowed.
    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    static var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!
    }

    /// One notification for everything a sync downloaded, grouped by OS version.
    func announceReady(_ items: [(firmware: Firmware, models: [String])], name: (String) -> String) {
        guard !items.isEmpty else { return }
        var byVersion: [String: [String]] = [:]
        for item in items { byVersion[item.firmware.version, default: []].append(contentsOf: item.models) }
        let versions = byVersion.keys.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        let allModels = versions.flatMap { byVersion[$0] ?? [] }

        let content = UNMutableNotificationContent()
        if versions.count == 1, let version = versions.first {
            content.title = "\(Self.osName(for: allModels)) \(version) is ready"
            content.body = "Restore files for \(Self.list(allModels.map(name))) are downloaded and verified."
        } else {
            content.title = "\(items.count) new restore files are ready"
            content.body = versions
                .map { "\(Self.osName(for: byVersion[$0] ?? [])) \($0): \(Self.list((byVersion[$0] ?? []).map(name)))" }
                .joined(separator: "\n")
        }
        content.sound = .default
        post(content, id: "ready-\(versions.joined(separator: "-"))")
    }

    func announceFailures(_ count: Int) {
        guard count > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = count == 1 ? "A download failed" : "\(count) downloads failed"
        content.body = "Amphora will try again at the next check. Details are in Activity."
        post(content, id: "failed")
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private static func osName(for models: [String]) -> String {
        let families = Set(models.map(DeviceModel.family(of:)))
        let names = [(DeviceModel.Family.iPhone, "iOS"), (.iPad, "iPadOS"), (.mac, "macOS")]
            .filter { families.contains($0.0) }.map(\.1)
        switch names.count {
        case 0: return "iOS"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    private static func list(_ names: [String]) -> String {
        let unique = Array(NSOrderedSet(array: names)) as? [String] ?? names
        switch unique.count {
        case 0: return "your models"
        case 1: return unique[0]
        case 2: return "\(unique[0]) and \(unique[1])"
        default: return "\(unique[0]), \(unique[1]) and \(unique.count - 2) more"
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            openMainWindow?()
        }
    }
}
