import SwiftUI

@main
struct IPSWMirrorApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("IPSW Mirror", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
        }
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
