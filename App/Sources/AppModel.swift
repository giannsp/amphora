import Foundation
import IPSWMirrorCore
import Observation

/// App state. Settings live in the app's defaults domain (consulting.techne.ipswmirror),
/// so a configuration profile can set them later without code changes.
@MainActor
@Observable
final class AppModel {
    struct Row: Identifiable, Hashable {
        let device: DeviceModel
        let targetVersion: String
        var id: String { device.identifier }
    }

    enum Status: Equatable {
        case ready(String)
        case outdated(String)
        case missing
        case queued
        case downloading(Double)
        case verifying
        case failed(String)
    }

    private enum Key {
        static let selected = "SelectedModels"
        static let storePath = "StorePath"
        static let configurator = "ExportToConfigurator"
        static let prune = "PruneOldIPSWs"
        static let lastSync = "LastSync"
    }

    private let defaults = UserDefaults.standard

    var rows: [Row] = []
    var status: [String: Status] = [:]
    var log: [String] = []
    var lastError: String?
    var isLoading = false
    var isBusy = false
    var currentTask: Task<Void, Never>?

    var selected: Set<String> {
        didSet { defaults.set(selected.sorted(), forKey: Key.selected) }
    }
    var storePath: String {
        didSet { defaults.set(storePath, forKey: Key.storePath); refreshStatus() }
    }
    var exportToConfigurator: Bool {
        didSet { defaults.set(exportToConfigurator, forKey: Key.configurator) }
    }
    var prune: Bool {
        didSet { defaults.set(prune, forKey: Key.prune) }
    }
    var lastSync: Date? {
        didSet { defaults.set(lastSync, forKey: Key.lastSync) }
    }

    /// True when a configuration profile sets the value, so the UI shows it locked.
    func isManaged(_ key: String) -> Bool { defaults.objectIsForced(forKey: key) }
    var storePathManaged: Bool { isManaged(Key.storePath) }
    var selectionManaged: Bool { isManaged(Key.selected) }

    init() {
        selected = Set(defaults.stringArray(forKey: Key.selected) ?? [])
        storePath = defaults.string(forKey: Key.storePath) ?? Store.defaultRoot.path
        exportToConfigurator = defaults.bool(forKey: Key.configurator)
        prune = defaults.object(forKey: Key.prune) as? Bool ?? true
        lastSync = defaults.object(forKey: Key.lastSync) as? Date
    }

    var store: Store { Store(root: URL(fileURLWithPath: storePath, isDirectory: true)) }

    var bytesOnDisk: Int64 {
        store.ipswFiles().reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let feed = SOFAClient().fetch()
            async let devices = IPSWMeSource().devices()
            let targets = try await feed.targetVersions()
            let names = Dictionary((try? await devices)?.map { ($0.identifier, $0.name) } ?? [],
                                   uniquingKeysWith: { a, _ in a })
            rows = targets
                .map { Row(device: DeviceModel(identifier: $0.key, name: names[$0.key] ?? $0.key), targetVersion: $0.value) }
                .sorted { $0.device.identifier.localizedStandardCompare($1.device.identifier) == .orderedDescending }
            lastError = nil
            refreshStatus()
        } catch {
            lastError = "Could not load the SOFA feed: \(error.localizedDescription)"
        }
    }

    func refreshStatus() {
        let onDisk = store.readManifest().versionsByModel()
        for row in rows {
            if case .downloading = status[row.id] { continue }
            if case .verifying = status[row.id] { continue }
            if let version = onDisk[row.id] {
                status[row.id] = version == row.targetVersion ? .ready(version) : .outdated(version)
            } else {
                status[row.id] = .missing
            }
        }
    }

    // MARK: Actions

    func syncSelected() async {
        guard !selected.isEmpty else { return }
        await run(SyncOptions(models: Array(selected), prune: prune, exportToConfigurator: exportToConfigurator))
        lastSync = Date()
    }

    func downloadNow(_ identifier: String) async {
        await run(SyncOptions(models: [identifier], prune: false, exportToConfigurator: exportToConfigurator))
    }

    func cancel() {
        currentTask?.cancel()
    }

    private func run(_ options: SyncOptions) async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        for id in options.models { status[id] = .queued }

        let engine = SyncEngine(store: store)
        // AppModel lives as long as the app, so capturing it strongly is fine.
        let task = Task { [self] in
            do {
                let summary = try await engine.sync(options) { event in
                    await self.handle(event)
                }
                append("Finished: \(summary.downloaded) downloaded, \(summary.alreadyPresent) already present, "
                       + "\(summary.removed) removed, \(summary.problems) problem(s)")
            } catch is CancellationError {
                append("Cancelled. Partial downloads resume next time.")
            } catch {
                lastError = error.localizedDescription
                append("Error: \(error.localizedDescription)")
            }
        }
        currentTask = task
        await task.value
        currentTask = nil
        isBusy = false
        refreshStatus()
    }

    private var modelsByFile: [String: [String]] = [:]

    private func handle(_ event: SyncEvent) {
        switch event {
        case let .planned(items):
            modelsByFile = Dictionary(items.map { ($0.firmware.fileName, $0.models) }, uniquingKeysWith: { a, _ in a })
            let missing = items.filter { !$0.onDisk }.count
            append("Plan: \(items.count) file(s), \(missing) to download")
        case let .warning(message):
            append("⚠︎ \(message)")
        case let .downloadStarted(fw):
            append("Downloading \(fw.fileName)")
            set(fw, .downloading(0))
        case let .progress(fw, received, total):
            set(fw, .downloading(total > 0 ? Double(received) / Double(total) : 0))
        case let .verifying(fw):
            set(fw, .verifying)
        case let .completed(fw):
            append("Verified \(fw.fileName)")
            set(fw, .ready(fw.version))
        case let .failed(fw, message):
            append("Failed \(fw.fileName): \(message)")
            set(fw, .failed(message))
        case let .removed(url):
            append("Removed \(url.lastPathComponent)")
        }
    }

    private func set(_ firmware: Firmware, _ value: Status) {
        for id in modelsByFile[firmware.fileName] ?? [firmware.identifier] { status[id] = value }
    }

    private func append(_ line: String) {
        let time = Date().formatted(date: .omitted, time: .shortened)
        log.append("\(time)  \(line)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}
