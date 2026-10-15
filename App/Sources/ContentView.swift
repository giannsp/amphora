import AppKit
import AmphoraCore
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
    @Environment(\.openWindow) private var openWindow
    @State private var pane: Pane? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Label("Overview", systemImage: "square.grid.2x2")
                    .tag(Pane.overview)
                Label("My Devices", systemImage: model.modelSource == .jamf ? "server.rack" : "checkmark.circle")
                    .badge(model.attentionRows.count)
                    .help("Models that still need their restore file")
                    .tag(Pane.kept)
                Label("Downloaded", systemImage: "internaldrive")
                    .tag(Pane.files)
                Label("Activity", systemImage: "list.bullet.rectangle")
                    .badge(model.unseenWarnings)
                    .tag(Pane.activity)

                Section("All Models") {
                    Label("iPhone", systemImage: "iphone")
                        .tag(Pane.devices(.iPhone))
                    Label("iPad", systemImage: "ipad")
                        .tag(Pane.devices(.iPad))
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
            if !model.pendingKeptModels.isEmpty && model.modelSource == .curated {
                Button("Delete and Stop Keeping Current", role: .destructive) {
                    model.confirmDelete(stopKeeping: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.deletionMessage)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isBusy {
                    SyncProgressButton()
                } else {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await model.syncSelected() }
                    }
                    .disabled(model.keptIDs.isEmpty && model.modelSource == .curated)
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
        .sheet(isPresented: Binding(get: { model.showOnboarding },
                                    set: { model.showOnboarding = $0 })) {
            OnboardingView()
                .environment(model)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: Binding(get: { model.showConfiguratorSetup },
                                    set: { model.showConfiguratorSetup = $0 })) {
            ConfiguratorSetupView()
                .environment(model)
        }
        .task {
            // Syncing itself is scheduled by AppModel and runs with or without this window.
            model.checkConfiguratorAccess()
            if !model.onboardingCompleted {
                model.showOnboarding = true
            } else if model.shouldOfferConfiguratorSetup {
                model.showConfiguratorSetup = true
            }
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            let open = openWindow
            Notifier.shared.openMainWindow = { open(id: "main") }
        }
        .onDisappear {
            // Window closed: keep working from the menu bar, without a Dock icon.
            if model.showInMenuBar { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
