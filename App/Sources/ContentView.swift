import AppKit
import IPSWMirrorCore
import SwiftUI

enum Pane: Hashable {
    case overview
    case devices(DeviceModel.Family)
    case kept
    case files
    case activity
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var pane: Pane? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Label("Overview", systemImage: "square.grid.2x2")
                    .tag(Pane.overview)

                Section("Devices") {
                    Label("iPhone", systemImage: "iphone")
                        .badge(model.keptCount(.iPhone))
                        .tag(Pane.devices(.iPhone))
                    Label("iPad", systemImage: "ipad")
                        .badge(model.keptCount(.iPad))
                        .tag(Pane.devices(.iPad))
                }

                Section("Library") {
                    Label("Kept Current", systemImage: "checkmark.circle")
                        .badge(model.attentionRows.count)
                        .tag(Pane.kept)
                    Label("Downloaded", systemImage: "internaldrive")
                        .tag(Pane.files)
                    Label("Activity", systemImage: "list.bullet.rectangle")
                        .badge(model.unseenWarnings)
                        .tag(Pane.activity)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch pane ?? .overview {
            case .overview:
                OverviewView { pane = .devices($0) }
            case let .devices(family):
                DeviceListView(scope: .family(family))
                    .id(family)
            case .kept:
                DeviceListView(scope: .kept)
            case .files:
                FilesView()
            case .activity:
                ActivityView()
            }
        }
        .confirmationDialog(
            model.deletionTitle,
            isPresented: Binding(
                get: { model.pendingDeletion != nil },
                set: { if !$0 { model.pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { model.confirmDelete(stopKeeping: false) }
            if !model.pendingKeptModels.isEmpty {
                Button("Delete and Stop Keeping Current", role: .destructive) {
                    model.confirmDelete(stopKeeping: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.deletionMessage)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isBusy {
                    if let progress = model.progress, progress.fileCount > 0 {
                        ProgressView(value: progress.fraction)
                            .frame(width: 110)
                            .help("\(Int(progress.fraction * 100))% of \(plural(progress.fileCount, "file"))")
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Cancel", systemImage: "stop.circle") { model.cancel() }
                        .help("Stop now. Downloads resume where they left off next time.")
                } else {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await model.syncSelected() }
                    }
                    .disabled(model.selected.isEmpty)
                    .help("Download what kept models need, then clean up (⌘R)")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.checkConfiguratorAccess()
        }
        .onChange(of: pane) { _, pane in
            if pane == .activity { model.unseenWarnings = 0 }
        }
        .sheet(isPresented: Binding(get: { model.showConfiguratorSetup },
                                    set: { model.showConfiguratorSetup = $0 })) {
            ConfiguratorSetupView()
                .environment(model)
        }
        .task {
            model.checkConfiguratorAccess()
            if model.shouldOfferConfiguratorSetup { model.showConfiguratorSetup = true }
            await model.load()
            // Keep current while the app is open. Background sync without the app arrives in v0.3.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppModel.syncInterval))
                guard !Task.isCancelled else { break }
                await model.load()
                await model.syncSelected()
            }
        }
    }
}
