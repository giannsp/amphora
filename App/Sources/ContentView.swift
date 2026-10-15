import IPSWMirrorCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selectedOnly = false
    @State private var showActivity = false

    private var visibleRows: [AppModel.Row] {
        model.rows.filter { row in
            (!selectedOnly || model.selected.contains(row.id))
                && (search.isEmpty
                    || row.device.name.localizedCaseInsensitiveContains(search)
                    || row.device.identifier.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            ForEach(DeviceModel.Family.allCases, id: \.self) { family in
                let rows = visibleRows.filter { $0.device.family == family }
                if !rows.isEmpty {
                    Section(family == .iPhone ? "iPhone" : "iPad") {
                        ForEach(rows) { row in
                            ModelRow(row: row)
                        }
                    }
                }
            }
        }
        .overlay {
            if model.isLoading && model.rows.isEmpty {
                ProgressView("Loading current releases…")
            } else if !model.rows.isEmpty && visibleRows.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search, prompt: "Model name or identifier")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $selectedOnly) {
                    Label("Selected Only", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Show only the models you keep current")

                if model.isBusy {
                    Button {
                        model.cancel()
                    } label: {
                        Label("Cancel", systemImage: "stop.circle")
                    }
                    .help("Stop the current download. It resumes next time.")
                } else {
                    Button {
                        Task { await model.syncSelected() }
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.selected.isEmpty)
                    .help("Download what the selected models need, then clean up")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar(showActivity: $showActivity)
        }
        .task {
            await model.load()
            // Keep current while the app is open. Background sync without the app arrives in v0.3.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
                await model.load()
                await model.syncSelected()
            }
        }
    }
}

private struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let row: AppModel.Row

    private var isSelected: Binding<Bool> {
        Binding(
            get: { model.selected.contains(row.id) },
            set: { keep in
                if keep { model.selected.insert(row.id) } else { model.selected.remove(row.id) }
            }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Keep current", isOn: isSelected)
                .labelsHidden()
                .disabled(model.selectionManaged)
                .help(model.selectionManaged ? "Set by your organization" : "Keep this model's IPSW current")

            VStack(alignment: .leading, spacing: 2) {
                Text(row.device.name)
                Text(row.device.identifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusView(status: model.status[row.id] ?? .missing, target: row.targetVersion)
                .frame(width: 170, alignment: .trailing)

            Button {
                Task { await model.downloadNow(row.id) }
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .disabled(model.isBusy)
            .help(model.selected.contains(row.id)
                  ? "Download now"
                  : "Download now. Removed at the next sync unless this model is ticked.")
        }
        .padding(.vertical, 2)
    }
}

private struct StatusView: View {
    let status: AppModel.Status
    let target: String

    var body: some View {
        switch status {
        case let .ready(version):
            Label(version, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .outdated(version):
            Label("\(version) → \(target)", systemImage: "arrow.up.circle")
                .foregroundStyle(.orange)
        case .missing:
            Text("\(target) · not on disk")
                .foregroundStyle(.secondary)
        case .queued:
            Text("Queued")
                .foregroundStyle(.secondary)
        case let .downloading(fraction):
            HStack(spacing: 6) {
                ProgressView(value: fraction)
                    .frame(width: 100)
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Verifying")
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(message)
        }
    }
}

private struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @Binding var showActivity: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(summary)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(showActivity ? "Hide Activity" : "Show Activity") {
                    showActivity.toggle()
                }
                .buttonStyle(.link)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if showActivity {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.log.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(height: 140)
                    .background(.background.secondary)
                    .onChange(of: model.log.count) { _, count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .background(.bar)
    }

    private var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: model.bytesOnDisk, countStyle: .file)
        var parts = ["\(model.selected.count) selected", "\(size) on disk"]
        if let last = model.lastSync {
            parts.append("last sync \(last.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}
