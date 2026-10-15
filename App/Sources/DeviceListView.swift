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
        switch scope {
        case let .family(family): return model.rows.filter { $0.device.family == family }
        case .kept: return model.keptRows
        }
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
                Label("Nothing kept current yet", systemImage: "checkmark.circle")
            } description: {
                Text("Tick models under iPhone or iPad. Their restore files stay downloaded and up to date.")
            }
        } else if rows.isEmpty && !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
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
            }
            .listStyle(.inset)
            .animation(.ui, value: rows.map(\.id))
        }
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
        case .kept: return "Kept Current"
        }
    }

    private var subtitle: String {
        let kept = scopedRows.filter { model.selected.contains($0.id) }.count
        switch scope {
        case .family: return "\(plural(scopedRows.count, "model")), \(kept) kept current"
        case .kept: return "\(model.readyCount) of \(kept) ready"
        }
    }
}
