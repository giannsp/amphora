import AppKit
import AmphoraCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var secret = ""
    @State private var testResult: String?
    @State private var notificationsDenied = false

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Picker("Keep current", selection: $model.modelSource) {
                    ForEach(AppModel.ModelSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(model.sourceManaged)

                if model.modelSource == .jamf {
                    TextField("Jamf Pro address", text: $model.jamfURL, prompt: Text("https://yourorg.jamfcloud.com"))
                        .disabled(model.jamfURLManaged)
                    TextField("API client ID", text: $model.jamfClientID)
                        .disabled(model.jamfClientIDManaged)
                    LabeledContent("Client secret") {
                        HStack {
                            SecureField("Client secret", text: $secret,
                                        prompt: Text(model.jamfSecretSaved ? "Saved in the Keychain" : "Paste the secret"))
                                .labelsHidden()
                                .onSubmit(saveSecret)
                            Button("Save", action: saveSecret)
                                .disabled(secret.isEmpty || model.jamfClientID.isEmpty)
                        }
                    }
                    Toggle("Only managed devices", isOn: $model.jamfManagedOnly)
                    LabeledContent("Inventory") {
                        HStack {
                            jamfStatus
                            Button(model.isFetchingJamf ? "Checking…" : "Test Connection") {
                                Task {
                                    saveSecret()
                                    let ok = await model.refreshJamf()
                                    testResult = ok ? nil : model.jamfError
                                }
                            }
                            .disabled(!model.jamfConfigured || model.isFetchingJamf)
                        }
                    }
                    if !model.jamfUnsupported.isEmpty {
                        Text("No signed release: \(model.jamfUnsupported.map { "\(model.displayName($0)) (\($0))" }.joined(separator: ", ")). They're listed in My Devices, with nothing to download.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Models")
            } footer: {
                if model.modelSource == .jamf {
                    Text("Create an API Role with only \"Read Mobile Devices\" and an API Client using it (Jamf Pro → Settings → API Roles and Clients). Amphora reads model identifiers only, and never changes anything in Jamf Pro. The secret is stored in your Keychain.")
                        .foregroundStyle(.secondary)
                }
            }

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
                Text("Restores in Apple Configurator then start without a download. On APFS the copy is a clone and uses no extra space. macOS protects Configurator's folder, so Amphora needs Full Disk Access; on managed Macs a Jamf PPPC profile grants it.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin },
                                                      set: { model.setOpenAtLogin($0) }))
                if model.loginItemStatus == .requiresApproval {
                    LabeledContent("Needs approval") {
                        Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error = model.loginItemError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Toggle("Keep running in the menu bar", isOn: $model.showInMenuBar)
                Toggle("Notify me when new restore files are ready", isOn: $model.notify)
                    .onChange(of: model.notify) { _, on in
                        if on { Task { await Notifier.shared.requestAuthorization(); await checkNotifications() } }
                    }
                if model.notify && notificationsDenied {
                    LabeledContent("Notifications are off for Amphora in System Settings") {
                        Button("Open Notification Settings") { NSWorkspace.shared.open(Notifier.settingsURL) }
                    }
                    .foregroundStyle(.orange)
                }
                Picker("Sync every", selection: $model.syncIntervalHours) {
                    ForEach(AppModel.syncIntervalChoices, id: \.self) { hours in
                        Text(hours == 1 ? "hour" : "\(hours) hours").tag(hours)
                    }
                }
            } header: {
                Text("Background")
            } footer: {
                Text("With the menu bar on, closing the window keeps Amphora syncing in the background. Downloads keep the Mac from idle sleep until they finish.")
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: AppInfo.version)
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
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .task { await checkNotifications() }
        .onChange(of: model.modelSource) { _, source in
            if source == .jamf && model.jamfConfigured { Task { await model.refreshJamf() } }
        }
    }

    @ViewBuilder
    private var jamfStatus: some View {
        if let error = testResult ?? model.jamfError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        } else if let fetched = model.jamfFetched, !model.jamfCounts.isEmpty {
            let devices = model.jamfCounts.values.reduce(0, +)
            let supported = model.jamfCounts.count - model.jamfUnsupported.count
            let models = model.jamfUnsupported.isEmpty
                ? plural(model.jamfCounts.count, "model")
                : "\(plural(model.jamfCounts.count, "model")), \(supported) with a signed release"
            Label("\(plural(devices, "device")) · \(models) · \(fetched.formatted(.relative(presentation: .named)))",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Text("Not checked yet")
                .foregroundStyle(.secondary)
        }
    }

    private func checkNotifications() async {
        notificationsDenied = await Notifier.shared.authorizationStatus() == .denied
    }

    private func saveSecret() {
        guard !secret.isEmpty else { return }
        model.saveJamfSecret(secret)
        secret = ""
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
