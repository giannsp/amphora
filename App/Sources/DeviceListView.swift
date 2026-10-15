import IPSWMirrorCore
import SwiftUI

/// Models grouped by the OS release they get, newest first, so it's obvious which models stay on an older iOS.
struct DeviceListView: View {
    enum Scope: Hashable {
        case family(DeviceModel.Family)
        case kept
    }

    private struct ReleaseGroup: Identifiable {
        let major: Int
        let rows: [AppModel.Row]
        var id: Int { major }
    }

    @Environment(AppModel.self) private var model
    let scope: Scope
    @State private var search = ""

    private var scopedRows: [AppModel.Row] {
        let rows: [AppModel.Row]
        switch scope {
        case let .family(family): rows = model.rows.filter { $0.device.family == family }
        case .kept: rows = model.keptRows
        }
        guard model.modelSource == .jamf else { return rows }
        // Most devices first: that's where a restore is most likely needed.
        return rows.sorted {
            let a = model.jamfCounts[$0.id] ?? 0, b = model.jamfCounts[$1.id] ?? 0
            return a != b ? a > b : $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    /// Jamf models with no signed release: shown so the fleet adds up, never downloaded.
    private var unsupportedIDs: [String] {
        guard scope == .kept, model.modelSource == .jamf else { return [] }
        return model.jamfUnsupported
            .filter { search.isEmpty
                || $0.localizedCaseInsensitiveContains(search)
                || model.displayName($0).localizedCaseInsensitiveContains(search) }
            .sorted { (model.jamfCounts[$0] ?? 0) > (model.jamfCounts[$1] ?? 0) }
    }

    /// Kept models in this list that still need their file.
    private var missingRows: [AppModel.Row] {
        scopedRows.filter { model.isKept($0.id) && model.status[$0.id]?.isReady != true }
    }

    private var rows: [AppModel.Row] {
        guard !search.isEmpty else { return scopedRows }
        return scopedRows.filter {
            $0.device.name.localizedCaseInsensitiveContains(search)
                || $0.device.identifier.localizedCaseInsensitiveContains(search)
        }
    }

    private var groups: [ReleaseGroup] {
        Dictionary(grouping: rows, by: \.major)
            .map { ReleaseGroup(major: $0.key, rows: $0.value) }
            .sorted { $0.major > $1.major }
    }

    var body: some View {
        content
            .searchable(text: $search, placement: .toolbar, prompt: "Name or identifier")
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
    }

    @ViewBuilder
    private var content: some View {
        if model.rows.isEmpty && model.isLoading {
            ProgressView("Loading current releases…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scope == .kept && model.keptRows.isEmpty {
            ContentUnavailableView {
                Label("No devices yet", systemImage: "checkmark.circle")
            } description: {
                Text(model.modelSource == .jamf
                     ? "Models come from your Jamf Pro inventory. Connect Jamf Pro in Settings."
                     : "Tick the models you support under All Models. Their restore files stay downloaded and up to date.")
            }
        } else if rows.isEmpty && unsupportedIDs.isEmpty && !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            VStack(spacing: 0) {
                if model.isBusy || !missingRows.isEmpty {
                    DownloadBar(missing: missingRows.count)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                list
            }
            .animation(.ui, value: missingRows.isEmpty)
        }
    }

    private var list: some View {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.rows) { row in
                            DeviceRow(row: row)
                        }
                    } header: {
                        header(for: group)
                    }
                }
                if !unsupportedIDs.isEmpty {
                    Section {
                        ForEach(unsupportedIDs, id: \.self) { id in
                            UnsupportedRow(identifier: id)
                        }
                    } header: {
                        HStack {
                            Text("No signed release")
                            Spacer()
                            Text(plural(unsupportedIDs.count, "model"))
                                .foregroundStyle(.tertiary)
                        }
                    } footer: {
                        Text("Apple signs no release at all for these models any more, so there's no restore file to keep.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
            .animation(.ui, value: rows.map(\.id))
    }

    private func header(for group: ReleaseGroup) -> some View {
        let newest = model.rows.map(\.major).max() ?? group.major
        let name: String = switch scope {
        case .family(.iPhone): "iOS"
        case .family(.iPad): "iPadOS"
        case .kept: "iOS / iPadOS"
        }
        return HStack(spacing: 6) {
            Text("\(name) \(group.major)")
            if group.major < newest {
                Text("· older models")
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(plural(group.rows.count, "model"))
                .foregroundStyle(.tertiary)
        }
    }

    private var title: String {
        switch scope {
        case .family(.iPhone): return "iPhone"
        case .family(.iPad): return "iPad"
        case .kept: return "My Devices"
        }
    }

    private var subtitle: String {
        let kept = scopedRows.filter { model.isKept($0.id) }.count
        let jamf = model.modelSource == .jamf
        switch scope {
        case .family:
            return "Every \(scope == .family(.iPhone) ? "iPhone" : "iPad") a current release supports · \(kept) in My Devices"
        case .kept:
            var text = "\(plural(kept, "model")) \(jamf ? "from Jamf Pro" : "you chose") · \(model.readyCount) of \(kept) ready to restore"
            if jamf, !model.jamfUnsupported.isEmpty {
                text += " · \(model.jamfUnsupported.count) with no signed release"
            }
            return text
        }
    }
}

/// Says what is missing and offers the one action that fixes it. During a sync, shows how far it got.
private struct DownloadBar: View {
    @Environment(AppModel.self) private var model
    let missing: Int

    var body: some View {
        HStack(spacing: 12) {
            if model.isBusy {
                let progress = model.progress
                VStack(alignment: .leading, spacing: 4) {
                    if let progress, progress.fileCount > 0 {
                        Text("Downloading \(min(progress.finished.count + 1, progress.fileCount)) of \(plural(progress.fileCount, "file"))")
                            .fontWeight(.medium)
                        ProgressView(value: progress.fraction)
                            .frame(maxWidth: 320)
                    } else {
                        Text("Checking for new releases…")
                            .fontWeight(.medium)
                    }
                }
                Spacer()
                Button("Stop") { model.cancel() }
            } else {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(plural(missing, "model")) \(missing == 1 ? "needs its" : "need their") restore file")
                        .fontWeight(.medium)
                    Text("Download now, so a restore never waits for a 10–15 GB download.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Download All") { Task { await model.syncSelected() } }
                    .buttonStyle(.borderedProminent)
                    .help("Sync now (⌘R): download what's missing, then clean up")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.07))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A model Jamf holds that no signed release supports: visible, but nothing to download.
private struct UnsupportedRow: View {
    @Environment(AppModel.self) private var model
    let identifier: String

    var body: some View {
        HStack(spacing: 12) {
            DeviceGlyph(family: identifier.hasPrefix("iPad") ? .iPad : .iPhone)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName(identifier))
                    .fontWeight(.medium)
                HStack(spacing: 4) {
                    Text(identifier)
                        .font(.caption.monospaced())
                    if let count = model.jamfCounts[identifier] {
                        Text("· \(plural(count, "device")) in Jamf")
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Label("No signed release", systemImage: "nosign")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: .capsule)
                .help("Apple no longer signs a release for this model, so it can't be restored with an IPSW from Apple")
        }
        .padding(.vertical, 4)
        .opacity(0.75)
    }
}
