import AmphoraCore
import AppKit
import SwiftUI

/// First-launch setup: where the device list comes from, the Jamf Pro connection,
/// Apple Configurator access, and background behaviour. Everything it sets stays editable in Settings.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, source, devices, configurator, background, ready
    }

    @Environment(AppModel.self) private var model
    @State private var step: Step = .welcome
    @State private var forward = true
    @State private var wantsLogin = true
    /// Survives a Quit & Reopen (macOS offers one after granting Full Disk Access): setup resumes there.
    @AppStorage("OnboardingStep") private var savedStep = 0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                content
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 36)
            .padding(.top, 32)
            .clipped()

            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(width: 680, height: 580)
        .onAppear {
            wantsLogin = model.openAtLogin || !model.onboardingCompleted
            step = Step(rawValue: savedStep) ?? .welcome
        }
        .onChange(of: step) { _, step in savedStep = step.rawValue }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .source: SourceStep()
        case .devices:
            if model.modelSource == .jamf { JamfStep() } else { ModelPickerStep() }
        case .configurator: ConfiguratorStep()
        case .background: BackgroundStep(wantsLogin: $wantsLogin)
        case .ready: ReadyStep(wantsLogin: wantsLogin)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step != .welcome {
                Button("Back") { go(-1) }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Circle()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
            Spacer()
            switch step {
            case .welcome:
                Button("Get Started") { go(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .devices:
                if !devicesReady {
                    Button("Skip for Now") { go(1) }
                }
                Button("Continue") { go(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!devicesReady)
            case .configurator:
                Button(model.configuratorAccess == .granted || !model.exportToConfigurator ? "Continue" : "Continue Without") { go(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .ready:
                Button("Finish") { finish(download: false) }
                if !model.keptIDs.isEmpty {
                    Button("Download Now") { finish(download: true) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            default:
                Button("Continue") { go(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var devicesReady: Bool {
        model.modelSource == .jamf
            ? model.jamfConfigured && model.jamfError == nil && !model.jamfCounts.isEmpty
            : !model.selected.isEmpty
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(.ui) { step = next }
    }

    private func finish(download: Bool) {
        savedStep = 0
        model.completeOnboarding(openAtLogin: wantsLogin)
        if model.notify { Task { await Notifier.shared.requestAuthorization() } }
        if download { Task { await model.syncSelected() } }
    }
}

// MARK: - Steps

private struct StepHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 20)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Welcome to Amphora")
                    .font(.largeTitle.weight(.semibold))
                Text("Restore files, stored and ready.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                feature("arrow.down.circle", "Always the latest signed IPSW",
                        "For every iPhone and iPad model you support, downloaded, verified and replaced when Apple releases a new version.")
                feature("bolt.fill", "Restores start right away",
                        "Apple Configurator finds the file already on this Mac. No 12 GB wait at the service desk.")
                feature("menubar.rectangle", "Works quietly in the background",
                        "Lives in the menu bar and keeps everything current, even after a restart.")
            }
            .padding(.top, 8)
            .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity)
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SourceStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(symbol: "iphone.gen3",
                       title: "Which devices should Amphora keep ready?",
                       subtitle: "Amphora keeps a restore file for every model in this list. You can change this later in Settings.")
            VStack(spacing: 12) {
                card(.jamf, symbol: "server.rack", title: "My Jamf Pro inventory", badge: "Recommended",
                     text: "Every iPhone and iPad model you own, read from Jamf Pro with a read-only API client. New models are picked up automatically.")
                card(.curated, symbol: "checklist", title: "Models I choose", badge: nil,
                     text: "Pick models from a list. Good without Jamf Pro, or when you only restore a few models.")
            }
            if model.sourceManaged {
                Label("Set by your organization", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
        }
    }

    private func card(_ source: AppModel.ModelSource, symbol: String, title: String, badge: String?, text: String) -> some View {
        let selected = model.modelSource == source
        return Button {
            withAnimation(.ui) { model.modelSource = source }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).fontWeight(.semibold)
                        if let badge {
                            Text(badge)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12), in: .capsule)
                        }
                    }
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(model.sourceManaged)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct JamfStep: View {
    @Environment(AppModel.self) private var model
    @State private var secret = ""
    @State private var showHelp = false
    @State private var tested = false

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                StepHeader(symbol: "server.rack",
                           title: "Connect to Jamf Pro",
                           subtitle: "Amphora reads model identifiers only, and never changes anything in Jamf Pro.")

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Jamf Pro address").gridColumnAlignment(.trailing)
                        TextField("", text: $model.jamfURL, prompt: Text(verbatim: "https://yourorg.jamfcloud.com"))
                            .disabled(model.jamfURLManaged)
                    }
                    GridRow {
                        Text("API client ID")
                        TextField("", text: $model.jamfClientID, prompt: Text("From API Roles and Clients"))
                            .disabled(model.jamfClientIDManaged)
                    }
                    GridRow {
                        Text("Client secret")
                        SecureField("", text: $secret,
                                    prompt: Text(model.jamfSecretSaved ? "Saved in the Keychain" : "Paste the secret"))
                    }
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Toggle("Count managed devices only", isOn: $model.jamfManagedOnly)
                    }
                }
                .textFieldStyle(.roundedBorder)

                HStack(spacing: 12) {
                    Button(model.isFetchingJamf ? "Connecting…" : "Test Connection", action: test)
                        .disabled(model.jamfURL.isEmpty || model.jamfClientID.isEmpty
                                  || (secret.isEmpty && !model.jamfSecretSaved) || model.isFetchingJamf)
                    if model.isFetchingJamf { ProgressView().controlSize(.small) }
                    result
                }
                .padding(.top, 14)

                DisclosureGroup(isExpanded: $showHelp) {
                    VStack(alignment: .leading, spacing: 8) {
                        helpStep(1, "In Jamf Pro, open **Settings → System → API Roles and Clients**.")
                        helpStep(2, "**API Roles → New:** name it \"Amphora (read-only)\" and add only the privilege **Read Mobile Devices**.")
                        helpStep(3, "**API Clients → New:** name it \"Amphora\", choose that role, and set **Enable API client**.")
                        helpStep(4, "Click **Generate client secret** and copy the client ID and secret here. Jamf shows the secret once.")
                        Text("The secret is stored in this Mac's Keychain, never in preferences or logs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    .padding(.top, 8)
                } label: {
                    Text("How do I create an API client?")
                        .fontWeight(.medium)
                }
                .padding(.top, 20)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var result: some View {
        if tested, !model.isFetchingJamf {
            if let error = model.jamfError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .lineLimit(2)
            } else if !model.jamfCounts.isEmpty {
                let devices = model.jamfCounts.values.reduce(0, +)
                Label("Connected: \(plural(devices, "device")), \(plural(model.jamfCounts.count, "model"))",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        } else if !tested, model.jamfConfigured, !model.jamfCounts.isEmpty, model.jamfError == nil {
            Label("Connected before: \(plural(model.jamfCounts.count, "model"))", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private func test() {
        if !secret.isEmpty {
            model.saveJamfSecret(secret)
            secret = ""
        }
        Task {
            await model.refreshJamf()
            tested = true
        }
    }

    private func helpStep(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

private struct ModelPickerStep: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    private var rows: [AppModel.Row] {
        let all = model.rows.sorted { $0.device.identifier.localizedStandardCompare($1.device.identifier) == .orderedDescending }
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.device.name.localizedCaseInsensitiveContains(search)
                || $0.device.identifier.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(symbol: "checklist",
                       title: "Choose your models",
                       subtitle: "Tick every iPhone and iPad model your service desk restores. Jamf Pro and Apple list them by identifier, for example iPhone16,1.")
            HStack {
                TextField("Search by name or identifier", text: $search)
                    .textFieldStyle(.roundedBorder)
                Text("\(model.selected.count) chosen")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.bottom, 8)

            if model.rows.isEmpty {
                ProgressView("Loading current models…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { row in
                    Toggle(isOn: Binding(get: { model.selected.contains(row.id) },
                                         set: { on in
                                             if on { model.selected.insert(row.id) } else { model.selected.remove(row.id) }
                                         })) {
                        HStack {
                            Text(row.device.name)
                            Spacer()
                            Text(row.device.identifier)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }
        }
    }
}

private struct ConfiguratorStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let granted = model.configuratorAccess == .granted

        VStack(alignment: .leading, spacing: 0) {
            StepHeader(symbol: granted ? "checkmark.shield.fill" : "lock.shield",
                       title: "Let restores start instantly",
                       subtitle: "Amphora can place each file in Apple Configurator's own folder, so its restores begin without downloading. macOS protects that folder and never asks for access itself, so it takes one manual step.")

            Toggle("Place restore files in Apple Configurator's folder", isOn: $model.exportToConfigurator)
                .disabled(model.configuratorManaged)
                .padding(.bottom, 14)

            if model.exportToConfigurator {
                if granted {
                    Label("Access granted. Restores in Apple Configurator will use Amphora's files.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if model.configuratorAccess == .configuratorNotFound {
                    Label("Apple Configurator hasn't been opened on this Mac yet. Open it once, then come back to this step.",
                          systemImage: "questionmark.app.dashed")
                        .foregroundStyle(.orange)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        row(1, "Open Full Disk Access") {
                            Button("Open Privacy Settings") {
                                NSWorkspace.shared.open(ConfiguratorCache.fullDiskAccessSettingsURL)
                            }
                        }
                        row(2, "Drag Amphora into the list") { DraggableAppIcon() }
                        row(3, "Switch it on. If macOS offers Quit & Reopen, choose it: setup continues here") { EmptyView() }
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for access…")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                    .padding(16)
                    .background(.background.secondary, in: .rect(cornerRadius: 12))
                    Text("On Macs managed with Jamf Pro, a PPPC profile grants this automatically. Without it, you can still drag a model onto a device in Apple Configurator.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                }
            }
        }
        .task {
            while !Task.isCancelled && model.configuratorAccess != .granted {
                model.checkConfiguratorAccess()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func row<Accessory: View>(_ n: Int, _ title: String, @ViewBuilder _ accessory: () -> Accessory) -> some View {
        HStack(spacing: 12) {
            Text("\(n)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.15), in: .circle)
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            accessory()
        }
    }
}

private struct BackgroundStep: View {
    @Environment(AppModel.self) private var model
    @Binding var wantsLogin: Bool

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 0) {
            StepHeader(symbol: "menubar.rectangle",
                       title: "Keep it running",
                       subtitle: "Amphora does its work in the background, so files are ready before anyone needs them.")
            Form {
                Toggle("Open Amphora at login", isOn: $wantsLogin)
                Toggle("Keep running in the menu bar when the window is closed", isOn: $model.showInMenuBar)
                Toggle("Notify me when new restore files are ready", isOn: $model.notify)
                Picker("Check for new releases every", selection: $model.syncIntervalHours) {
                    ForEach(AppModel.syncIntervalChoices, id: \.self) { hours in
                        Text(hours == 1 ? "hour" : "\(hours) hours").tag(hours)
                    }
                }
                LabeledContent("Store files in") {
                    HStack {
                        Text(model.storePath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                            .disabled(model.storePathManaged)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Text("Each IPSW is 7–15 GB. A dedicated folder is best: Amphora removes IPSWs in it that your devices no longer need.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose a dedicated folder for restore files"
        if panel.runModal() == .OK, let url = panel.url { model.storePath = url.path }
    }
}

private struct ReadyStep: View {
    @Environment(AppModel.self) private var model
    let wantsLogin: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Amphora is ready")
                    .font(.largeTitle.weight(.semibold))
                Text(model.keptIDs.isEmpty
                     ? "Add devices any time in Settings."
                     : "Download the restore files now, or let Amphora do it in the background.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                summary("iphone.gen3", deviceSummary)
                summary(model.configuratorAccess == .granted ? "bolt.fill" : "hand.draw",
                        model.exportToConfigurator && model.configuratorAccess == .granted
                            ? "Restores in Apple Configurator start without a download"
                            : "Drag a model onto a device in Apple Configurator to restore")
                summary("clock.arrow.circlepath",
                        "Checks every \(model.syncIntervalHours == 1 ? "hour" : "\(model.syncIntervalHours) hours")"
                            + (wantsLogin ? ", and opens at login" : ""))
                summary("internaldrive", model.storePath)
            }
            .padding(18)
            .frame(maxWidth: 480, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity)
    }

    private var deviceSummary: String {
        let count = model.keptIDs.count
        if model.modelSource == .jamf {
            return count == 0 ? "Jamf Pro: not connected yet" : "\(plural(count, "model")) from your Jamf Pro inventory"
        }
        return count == 0 ? "No models chosen yet" : "\(plural(count, "model")) you chose"
    }

    private func summary(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
    }
}
