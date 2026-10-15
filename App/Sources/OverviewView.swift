import IPSWMirrorCore
import SwiftUI

/// The answer first: are restores ready? Then the numbers behind it, then what needs attention.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    let browse: (DeviceModel.Family) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = model.lastError {
                    ErrorBanner(message: error)
                }

                ConfiguratorAccessBanner()

                JamfBanner()

                HeroCard(browse: browse)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    StatTile(title: "Ready to restore", value: "\(model.readyCount) of \(model.keptRows.count)",
                             detail: model.modelSource == .jamf ? "models from Jamf Pro" : "models you chose",
                             symbol: model.modelSource == .jamf ? "server.rack" : "checkmark.circle")
                    StatTile(title: "On disk",
                             value: ByteCountFormatter.string(fromByteCount: model.diskUsage, countStyle: .file),
                             detail: plural(model.fileCount, "IPSW file"), symbol: "internaldrive")
                    StatTile(title: "Latest release", value: model.latestVersion ?? "—",
                             detail: "iOS and iPadOS", symbol: "sparkles")
                    StatTile(title: "Last sync", value: lastSyncValue, detail: nextSyncDetail,
                             symbol: "clock.arrow.circlepath")
                }

                if !model.attentionRows.isEmpty && !model.isBusy {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Needs a download")
                            .font(.headline)
                        VStack(spacing: 0) {
                            ForEach(model.attentionRows) { row in
                                DeviceRow(row: row)
                                    .padding(.horizontal, 12)
                                if row.id != model.attentionRows.last?.id {
                                    Divider().padding(.leading, 92)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .background(.background.secondary, in: .rect(cornerRadius: 12))
                    }
                    .transition(.opacity)
                }
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(.ui, value: model.attentionRows.map(\.id))
        }
        .navigationTitle("Overview")
    }

    private var lastSyncValue: String {
        guard let last = model.lastSync else { return "Never" }
        return last.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    private var nextSyncDetail: String {
        guard let next = model.nextSync, !model.keptIDs.isEmpty else { return "Every \(model.syncIntervalHours) hours" }
        return next < Date() ? "Next: due now" : "Next: \(next.formatted(date: .omitted, time: .shortened))"
    }
}

private struct HeroCard: View {
    @Environment(AppModel.self) private var model
    let browse: (DeviceModel.Family) -> Void

    private struct HeroState: Equatable {
        var symbol: String
        var tint: Color
        var title: String
        var subtitle: String
    }

    private var state: HeroState {
        let kept = model.keptRows.count
        if model.isBusy {
            let files = model.progress?.fileCount ?? 0
            let done = model.progress?.finished.count ?? 0
            return HeroState(symbol: "arrow.down.circle", tint: .accentColor,
                         title: files == 0 ? "Checking for new releases…" : "Downloading \(min(done + 1, files)) of \(files)",
                         subtitle: model.progress?.current ?? "Comparing your models with the latest signed releases")
        }
        if kept == 0 && model.modelSource == .jamf {
            return HeroState(symbol: "server.rack", tint: .secondary,
                             title: model.jamfConfigured ? "No supported models in Jamf Pro yet" : "Connect to Jamf Pro",
                             subtitle: model.jamfConfigured
                                 ? "IPSW Mirror keeps every iPhone and iPad model in your inventory current."
                                 : "Add your Jamf Pro address and a read-only API client in Settings.")
        }
        if kept == 0 {
            return HeroState(symbol: "circle.dashed", tint: .secondary,
                         title: "Choose the models you support",
                         subtitle: "IPSW Mirror keeps their restore files downloaded, verified and up to date.")
        }
        if model.failedCount > 0 {
            return HeroState(symbol: "exclamationmark.triangle.fill", tint: .red,
                         title: "\(plural(model.failedCount, "download")) failed",
                         subtitle: "Details are in Activity. Sync again to retry; partial files resume.")
        }
        let waiting = kept - model.readyCount
        if waiting > 0 {
            return HeroState(symbol: "arrow.down.circle.fill", tint: .orange,
                         title: "\(plural(waiting, "model")) need a download",
                         subtitle: "Sync now so the next restore starts without waiting.")
        }
        return HeroState(symbol: "checkmark.seal.fill", tint: .green,
                     title: kept == 1 ? "Your model is ready to restore" : "All \(kept) models are ready to restore",
                     subtitle: model.exportToConfigurator && !model.configuratorBlocked
                         ? "Apple Configurator restores them without downloading."
                         : "To restore, drag a model onto the device in Apple Configurator.")
    }

    var body: some View {
        let state = state
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: state.symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(state.tint)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: model.readyCount)
                .frame(width: 48)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.title)
                    .font(.title2.weight(.semibold))
                Text(state.subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if model.isBusy, let progress = model.progress, progress.fileCount > 0 {
                    ProgressView(value: progress.fraction) {
                        EmptyView()
                    } currentValueLabel: {
                        Text("\(ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)) of "
                             + ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: 420)
                    .padding(.top, 6)
                }
            }

            Spacer(minLength: 16)

            if model.isBusy {
                Button("Cancel") { model.cancel() }
                    .controlSize(.large)
            } else if model.keptRows.isEmpty && model.modelSource == .jamf {
                SettingsLink { Text("Open Settings") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else if model.keptRows.isEmpty {
                Button("Browse iPhone Models") { browse(.iPhone) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button("Sync Now") { Task { await model.syncSelected() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .background(state.tint.opacity(0.08), in: .rect(cornerRadius: 16))
        .animation(.ui, value: state)
        .accessibilityElement(children: .contain)
    }
}

private struct ErrorBanner: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.red)
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Try Again") { Task { await model.load() } }
                .disabled(model.isLoading)
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 12))
    }
}

/// Jamf trouble, in plain words. Syncs keep using the last good inventory meanwhile.
private struct JamfBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.modelSource == .jamf, model.jamfConfigured, let error = model.jamfError {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(error)
                    if let fetched = model.jamfFetched {
                        Text("Using the inventory from \(fetched.formatted(.relative(presentation: .named))). Nothing is deleted because of this.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Try Again") { Task { await model.refreshJamf() } }
                    .disabled(model.isFetchingJamf)
                SettingsLink { Text("Settings") }
            }
            .padding(12)
            .background(Color.orange.opacity(0.10), in: .rect(cornerRadius: 12))
        }
    }
}
