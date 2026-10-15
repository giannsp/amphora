import AppKit
import SwiftUI

/// Every IPSW on disk, for manual cleanup. Deletion always goes through the shared confirmation in ContentView.
struct FilesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\AppModel.StoredFile.name)]

    private var files: [AppModel.StoredFile] {
        model.storedFiles.sorted(using: sortOrder)
    }

    var body: some View {
        content
            .navigationTitle("Downloaded")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem {
                    Button("Delete", systemImage: "trash") { model.requestDelete(selection) }
                        .disabled(selection.isEmpty || model.isBusy)
                        .help(model.isBusy ? "Wait for the current sync to finish" : "Delete the selected IPSW files")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.storedFiles.isEmpty {
            ContentUnavailableView("No IPSWs downloaded", systemImage: "internaldrive",
                                   description: Text("Files appear here after a sync or a download."))
        } else {
            Table(files, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("File", value: \.name) { file in
                    Text(file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.name)
                }
                TableColumn("Version") { file in
                    Text(file.version ?? "—")
                        .monospacedDigit()
                }
                .width(min: 60, ideal: 70, max: 90)
                TableColumn("Used by") { file in
                    Text(usedBy(file))
                        .foregroundStyle(file.models.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .help(file.models.map(model.displayName).joined(separator: "\n"))
                }
                TableColumn("Size", value: \.size) { file in
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        .monospacedDigit()
                }
                .width(min: 64, ideal: 80, max: 100)
            }
            .contextMenu(forSelectionType: String.self) { names in
                Button("Show in Finder") { reveal(names) }
                    .disabled(names.isEmpty)
                Divider()
                Button("Delete…", role: .destructive) { model.requestDelete(names) }
                    .disabled(names.isEmpty || model.isBusy)
            } primaryAction: { names in
                reveal(names)
            }
            .onDeleteCommand { model.requestDelete(selection) }
            .onChange(of: model.storedFiles) { _, files in
                selection.formIntersection(files.map(\.id))
            }
        }
    }

    private var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: model.diskUsage, countStyle: .file)
        return "\(plural(model.fileCount, "file")), \(size)"
    }

    private func usedBy(_ file: AppModel.StoredFile) -> String {
        guard let first = file.models.first else { return "Not tracked" }
        let name = model.displayName(first)
        return file.models.count == 1 ? name : "\(name) + \(file.models.count - 1) more"
    }

    private func reveal(_ names: Set<String>) {
        let urls = names.sorted().map { model.store.root.appendingPathComponent($0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
