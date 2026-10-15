import AppKit
import SwiftUI

/// The menu bar panel: the one-line answer, progress while syncing, and the few actions that matter.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.menuBarSymbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .fontWeight(.semibold)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if model.isBusy, let progress = model.progress, progress.fileCount > 0 {
                ProgressView(value: progress.fraction)
            }

            HStack {
                if model.isBusy {
                    Button("Stop") { model.cancel() }
                } else {
                    Button("Sync Now") { Task { await model.syncSelected() } }
                        .disabled(model.keptIDs.isEmpty && model.modelSource == .curated)
                }
                Spacer()
                Button("Open Amphora") { openMainWindow() }
                    .buttonStyle(.borderedProminent)
            }

            Divider()

            HStack {
                SettingsLink { Text("Settings…") }
                    .buttonStyle(.link)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.link)
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 300)
    }

    private var headline: String {
        let kept = model.keptRows.count
        if model.isBusy {
            guard let progress = model.progress, progress.fileCount > 0 else { return "Checking for new releases…" }
            return "Downloading \(min(progress.finished.count + 1, progress.fileCount)) of \(progress.fileCount)"
        }
        if kept == 0 { return model.modelSource == .jamf ? "Connect to Jamf Pro" : "No devices chosen yet" }
        if model.failedCount > 0 { return "\(plural(model.failedCount, "download")) failed" }
        let waiting = kept - model.readyCount
        if waiting > 0 { return "\(plural(waiting, "model")) \(waiting == 1 ? "needs a" : "need their") restore file" }
        return kept == 1 ? "Ready to restore" : "All \(kept) models ready to restore"
    }

    private var detail: String {
        if model.isBusy, let progress = model.progress, progress.fileCount > 0 {
            let done = ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
            return "\(done) of \(total)"
        }
        var parts: [String] = []
        if let last = model.lastSync {
            parts.append("Last sync \(last.formatted(.relative(presentation: .named)))")
        }
        if let next = model.nextSync, !model.keptIDs.isEmpty {
            parts.append(next <= Date() ? "next sync soon" : "next \(next.formatted(date: .omitted, time: .shortened))")
        }
        if model.modelSource == .jamf, model.jamfError != nil { parts.append("Jamf Pro unreachable") }
        if model.configuratorBlocked { parts.append("Configurator needs Full Disk Access") }
        return parts.isEmpty ? "Every \(model.syncIntervalHours) hours" : parts.joined(separator: " · ")
    }

    private var tint: Color {
        if model.isBusy { return .accentColor }
        if model.failedCount > 0 || model.configuratorBlocked { return .orange }
        return model.keptRows.isEmpty || model.readyCount < model.keptRows.count ? .secondary : .green
    }

    private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate()
    }
}
