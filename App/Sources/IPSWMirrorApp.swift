import SwiftUI

@main
struct IPSWMirrorApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("IPSW Mirror", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Sync Now") { Task { await model.syncSelected() } }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy || model.selected.isEmpty)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
