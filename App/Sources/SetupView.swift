import AppKit
import AmphoraCore
import SwiftUI

/// Guides the user through Full Disk Access, which macOS never prompts for.
/// Shown once on launch when access is missing, and from the Overview banner.
struct ConfiguratorSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var granted: Bool { model.configuratorAccess == .granted }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: granted ? "checkmark.shield.fill" : "lock.shield")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(granted ? Color.green : Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(granted ? "Amphora can reach Apple Configurator" : "Let Amphora reach Apple Configurator")
                        .font(.title2.weight(.semibold))
                    Text("So restores start without downloading, Amphora places each IPSW in Apple Configurator's folder. macOS protects that folder, and only you can allow access. macOS doesn't ask for this one, so here's how.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                SetupStep(number: 1, title: "Open Full Disk Access", done: granted) {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(ConfiguratorCache.fullDiskAccessSettingsURL)
                    }
                }
                SetupStep(number: 2, title: "Drag Amphora into the list", done: granted) {
                    DraggableAppIcon()
                }
                SetupStep(number: 3, title: "Switch it on, then choose Quit & Reopen", done: granted) {
                    EmptyView()
                }
            }
            .padding(16)
            .background(.background.secondary, in: .rect(cornerRadius: 12))

            Text("On Macs managed with Jamf Pro, a PPPC profile grants this automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                if granted {
                    Label("Access granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Waiting for access…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !granted {
                    Button("Don't Use Configurator") {
                        model.exportToConfigurator = false
                        close()
                    }
                    .help("Turn the cache off. You can still drag models onto devices in Apple Configurator.")
                    Button("Not Now") { close() }
                }
                Button("Done") { close() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!granted)
            }
        }
        .padding(24)
        .frame(width: 560)
        .animation(.ui, value: granted)
        .task {
            // Notice the grant without the user doing anything.
            while !Task.isCancelled && !granted {
                model.checkConfiguratorAccess()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func close() {
        model.configuratorSetupDismissed = true
        dismiss()
    }
}

private struct SetupStep<Accessory: View>: View {
    let number: Int
    let title: String
    let done: Bool
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.accentColor.opacity(0.15))
                if done {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)

            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Step \(number): \(title)")
            accessory()
        }
    }
}

/// The app's own icon, draggable into the Full Disk Access list.
private struct DraggableAppIcon: View {
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
                .scaleEffect(hovering ? 1.08 : 1)
            Text("Drag me")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary, in: .rect(cornerRadius: 10))
        .onHover { inside in
            withAnimation(.ui) { hovering = inside }
        }
        .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
        .help("Drag this icon into the Full Disk Access list in System Settings")
        .accessibilityLabel("Amphora app icon, drag into the Full Disk Access list")
    }
}
