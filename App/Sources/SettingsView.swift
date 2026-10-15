import AppKit
import IPSWMirrorCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.storePath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Choose…", action: chooseFolder)
                            .disabled(model.storePathManaged)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.storePath)])
                        }
                    }
                }
                Toggle("Delete IPSWs the selected models no longer need", isOn: $model.prune)
            } header: {
                Text("Storage")
            } footer: {
                Text("Use a dedicated folder. Cleanup deletes any .ipsw in it that the selected models don't need, and only runs after every download succeeded.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Also place IPSWs in Apple Configurator's cache", isOn: $model.exportToConfigurator)
            } header: {
                Text("Apple Configurator (experimental)")
            } footer: {
                Text("Restores in Apple Configurator then start without a download. On APFS the copy is a clone and uses no extra space.")
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: IPSWMirror.version)
                LabeledContent("Release data") {
                    Link("SOFA by MacAdmins", destination: URL(string: "https://sofa.macadmins.io")!)
                }
                LabeledContent("Firmware data") {
                    Link("ipsw.me", destination: URL(string: "https://ipsw.me")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose a dedicated folder for IPSW files"
        panel.directoryURL = URL(fileURLWithPath: model.storePath).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            model.storePath = url.path
        }
    }
}
