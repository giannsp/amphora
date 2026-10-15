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
                Toggle("Place IPSWs in Apple Configurator's cache", isOn: $model.exportToConfigurator)
                    .disabled(model.configuratorManaged)
                LabeledContent("Status") {
                    switch model.configuratorAccess {
                    case .granted:
                        Label("Working", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .denied:
                        Label("Needs Full Disk Access", systemImage: "lock.shield").foregroundStyle(.orange)
                    case .configuratorNotFound:
                        Label("Open Apple Configurator once", systemImage: "questionmark.app.dashed").foregroundStyle(.orange)
                    case nil:
                        Text("Off").foregroundStyle(.secondary)
                    }
                }
                if model.configuratorAccess == .denied {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(ConfiguratorCache.fullDiskAccessSettingsURL)
                    }
                }
            } header: {
                Text("Apple Configurator")
            } footer: {
                Text("Restores in Apple Configurator then start without a download. On APFS the copy is a clone and uses no extra space. macOS protects Configurator's folder, so IPSW Mirror needs Full Disk Access; on managed Macs a Jamf PPPC profile grants it.")
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
        .onAppear { model.checkConfiguratorAccess() }
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
