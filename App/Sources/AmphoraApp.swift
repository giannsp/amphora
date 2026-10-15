import AppKit
import SwiftUI

@main
struct AmphoraApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    private var model: AppModel { delegate.model }

    var body: some Scene {
        Window("Amphora", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Setup Assistant…") {
                    NSApp.setActivationPolicy(.regular)
                    model.showOnboarding = true
                }
            }
            CommandGroup(after: .newItem) {
                Button("Sync Now") { Task { await model.syncSelected() } }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy || (model.keptIDs.isEmpty && model.modelSource == .curated))
            }
        }

        MenuBarExtra(isInserted: Binding(get: { model.showInMenuBar },
                                         set: { model.showInMenuBar = $0 })) {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel("Amphora")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Owns the model so it outlives every window, and starts the background scheduler at launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.install()
        // Set up before notifications existed: ask once now. New users are asked in the setup assistant.
        if model.notify && model.onboardingCompleted {
            Task {
                if await Notifier.shared.authorizationStatus() == .notDetermined {
                    await Notifier.shared.requestAuthorization()
                }
            }
        }
        model.registerLoginItemOnFirstLaunch()
        model.startScheduler()

        // Started by macOS at login: stay in the menu bar instead of opening the window.
        if launchedAsLoginItem && model.showInMenuBar {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.identifier?.rawValue.contains("main") == true {
                    window.close()
                }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// With the menu bar item on, closing the window keeps the app (and its schedule) running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.showInMenuBar
    }

    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }
}
