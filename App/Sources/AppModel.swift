import Foundation
import IPSWMirrorCore
import Observation

/// App state. Settings live in the app's defaults domain (consulting.techne.ipswmirror),
/// so a configuration profile can set them without code changes.
@MainActor
@Observable
final class AppModel {
    struct Row: Identifiable, Hashable {
        let device: DeviceModel
        let targetVersion: String
        var id: String { device.identifier }
        /// OS major the model targets, e.g. 27. Older models stay on an older major.
        var major: Int { Int(targetVersion.split(separator: ".").first ?? "") ?? 0 }
    }

    enum Status: Equatable {
        case ready(String)
        case outdated(String)
        case missing
        case queued
        case downloading(Double)
        case verifying
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// Byte-level progress of the current run, so the UI can show one overall bar.
    struct SyncProgress: Equatable {
        var sizes: [String: Int64] = [:]
        var received: [String: Int64] = [:]
        var finished: Set<String> = []
        var current: String?

        var fileCount: Int { sizes.count }
        var totalBytes: Int64 { sizes.values.reduce(0, +) }
        var receivedBytes: Int64 { received.values.reduce(0, +) }
        var fraction: Double { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0 }
    }

    /// One IPSW in the store, with the models it serves (empty when the manifest doesn't know it).
    struct StoredFile: Identifiable, Hashable {
        let name: String
        let size: Int64
        let version: String?
        let models: [String]
        var id: String { name }
    }

    static let syncInterval: TimeInterval = 6 * 60 * 60

    private enum Key {
        static let selected = "SelectedModels"
        static let storePath = "StorePath"
        static let prune = "PruneOldIPSWs"
        static let configurator = "ExportToConfigurator"
        static let setupDismissed = "ConfiguratorSetupDismissed"
        static let lastSync = "LastSync"
    }

    private let defaults = UserDefaults.standard

    var rows: [Row] = []
    var status: [String: Status] = [:]
    var log: [String] = []
    var lastError: String?
    var isLoading = false
    var isBusy = false
    var progress: SyncProgress?
    var storedFiles: [StoredFile] = []
    /// File names waiting for the user to confirm deletion.
    var pendingDeletion: Set<String>?
    /// Warnings logged since the user last opened Activity.
    var unseenWarnings = 0
    var diskUsage: Int64 { storedFiles.reduce(0) { $0 + $1.size } }
    var fileCount: Int { storedFiles.count }
    private var currentTask: Task<Void, Never>?
    private var modelsByFile: [String: [String]] = [:]

    var selected: Set<String> {
        didSet { defaults.set(selected.sorted(), forKey: Key.selected) }
    }
    var storePath: String {
        didSet { defaults.set(storePath, forKey: Key.storePath); refreshStatus() }
    }
    var prune: Bool {
        didSet { defaults.set(prune, forKey: Key.prune) }
    }
    /// Place verified IPSWs in Apple Configurator's cache so its restores start without a download.
    var exportToConfigurator: Bool {
        didSet {
            defaults.set(exportToConfigurator, forKey: Key.configurator)
            checkConfiguratorAccess()
        }
    }
    var configuratorAccess: ConfiguratorCache.Access?
    /// The Full Disk Access setup sheet.
    var showConfiguratorSetup = false
    var configuratorSetupDismissed: Bool {
        didSet { defaults.set(configuratorSetupDismissed, forKey: Key.setupDismissed) }
    }

    /// Offer the setup sheet on launch once, unless an MDM manages the setting (a PPPC profile is the fix there).
    var shouldOfferConfiguratorSetup: Bool {
        exportToConfigurator && configuratorAccess == .denied && !configuratorSetupDismissed && !configuratorManaged
    }
    var lastSync: Date? {
        didSet { defaults.set(lastSync, forKey: Key.lastSync) }
    }

    init() {
        selected = Set(defaults.stringArray(forKey: Key.selected) ?? [])
        storePath = defaults.string(forKey: Key.storePath) ?? Store.defaultRoot.path
        prune = defaults.object(forKey: Key.prune) as? Bool ?? true
        exportToConfigurator = defaults.object(forKey: Key.configurator) as? Bool ?? true
        configuratorSetupDismissed = defaults.bool(forKey: Key.setupDismissed)
        lastSync = defaults.object(forKey: Key.lastSync) as? Date
    }

    // MARK: Derived

    var store: Store { Store(root: URL(fileURLWithPath: storePath, isDirectory: true)) }

    /// True when a configuration profile sets the value, so the UI shows it locked.
    var storePathManaged: Bool { defaults.objectIsForced(forKey: Key.storePath) }
    var selectionManaged: Bool { defaults.objectIsForced(forKey: Key.selected) }
    var configuratorManaged: Bool { defaults.objectIsForced(forKey: Key.configurator) }

    /// True when the export is on but macOS (or a missing Configurator) stops it.
    var configuratorBlocked: Bool {
        exportToConfigurator && configuratorAccess != nil && configuratorAccess != .granted
    }

    func checkConfiguratorAccess() {
        configuratorAccess = exportToConfigurator ? ConfiguratorCache.checkAccess() : nil
    }

    var keptRows: [Row] { rows.filter { selected.contains($0.id) } }
    var readyCount: Int { keptRows.filter { status[$0.id]?.isReady == true }.count }
    var failedCount: Int { keptRows.filter { status[$0.id]?.isFailed == true }.count }
    var attentionRows: [Row] { keptRows.filter { status[$0.id]?.isReady != true } }
    var nextSync: Date? { lastSync?.addingTimeInterval(Self.syncInterval) }

    var latestVersion: String? {
        rows.map(\.targetVersion).max { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    func keptCount(_ family: DeviceModel.Family) -> Int {
        keptRows.filter { $0.device.family == family }.count
    }

    func toggleKept(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
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
            lastError = "Couldn't load current releases from SOFA. \(error.localizedDescription)"
        }
    }

    func refreshStatus() {
        let manifest = store.readManifest()
        let entries = Dictionary(manifest.entries.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
        storedFiles = store.ipswFiles()
            .filter { $0.pathExtension == "ipsw" }
            .map { url in
                let name = url.lastPathComponent
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                // Apple names restore files "<model>_<version>_<build>_Restore.ipsw".
                let parsed = name.split(separator: "_").dropFirst().first.map(String.init)
                return StoredFile(name: name, size: Int64(size),
                                  version: entries[name]?.version ?? parsed,
                                  models: entries[name]?.models ?? [])
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let onDisk = manifest.versionsByModel()
        for row in rows {
            switch status[row.id] {
            case .downloading, .verifying, .queued: continue
            default: break
            }
            if let version = onDisk[row.id] {
                status[row.id] = version == row.targetVersion ? .ready(version) : .outdated(version)
            } else if status[row.id]?.isFailed != true {
                status[row.id] = .missing
            }
        }
    }

    // MARK: Manual deletion

    func displayName(_ identifier: String) -> String {
        rows.first { $0.id == identifier }?.device.name ?? identifier
    }

    func fileName(for identifier: String) -> String? {
        storedFiles.first { $0.models.contains(identifier) }?.name
    }

    /// The IPSW on disk for a model, for drag-to-restore and Show in Finder.
    func fileURL(for identifier: String) -> URL? {
        fileName(for: identifier).map { store.root.appendingPathComponent($0) }
    }

    func requestDelete(_ names: Set<String>) {
        guard !names.isEmpty, !isBusy else { return }
        pendingDeletion = names
    }

    func requestDelete(model identifier: String) {
        if let name = fileName(for: identifier) { requestDelete([name]) }
    }

    private var pendingFiles: [StoredFile] {
        guard let names = pendingDeletion else { return [] }
        return storedFiles.filter { names.contains($0.name) }
    }

    /// Kept-current models whose file is about to go: the next sync would download it again.
    var pendingKeptModels: [String] {
        pendingFiles.flatMap(\.models).filter { selected.contains($0) }
    }

    var deletionTitle: String {
        let files = pendingFiles
        if files.count == 1, let version = files[0].version { return "Delete the \(version) IPSW?" }
        return files.count == 1 ? "Delete \(files[0].name)?" : "Delete \(files.count) IPSW files?"
    }

    var deletionMessage: String {
        let files = pendingFiles
        let models = files.flatMap(\.models)
        let size = ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size }, countStyle: .file)
        var text = models.isEmpty ? "Frees \(size)." : "Used by \(nameList(models)). Frees \(size)."
        let kept = pendingKeptModels
        if !kept.isEmpty {
            text += " \(nameList(kept)) \(kept.count == 1 ? "is" : "are") kept current, "
                + "so the next sync downloads \(files.count == 1 ? "it" : "them") again."
        }
        return text
    }

    func confirmDelete(stopKeeping: Bool) {
        guard let names = pendingDeletion, !isBusy else { return }
        let models = pendingFiles.flatMap(\.models)
        pendingDeletion = nil
        for name in names.sorted() {
            do {
                try store.delete(fileNamed: name)
                append("Deleted \(name)")
            } catch {
                lastError = "Couldn't delete \(name). \(error.localizedDescription)"
                append("Error: couldn't delete \(name): \(error.localizedDescription)")
            }
        }
        if stopKeeping { selected.subtract(models) }
        for id in models { status[id] = nil }
        refreshStatus()
    }

    private func nameList(_ identifiers: [String]) -> String {
        let names = identifiers.map(displayName)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
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

    func clearLog() {
        log.removeAll()
    }

    private func run(_ options: SyncOptions) async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        progress = SyncProgress()
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
                unseenWarnings += 1
                append("Error: \(error.localizedDescription)")
            }
        }
        currentTask = task
        await task.value
        currentTask = nil
        isBusy = false
        progress = nil
        for id in options.models where status[id] == .queued { status[id] = nil }
        refreshStatus()
        checkConfiguratorAccess()
    }

    private func handle(_ event: SyncEvent) {
        switch event {
        case let .planned(items):
            modelsByFile = Dictionary(items.map { ($0.firmware.fileName, $0.models) }, uniquingKeysWith: { a, _ in a })
            let missing = items.filter { !$0.onDisk }
            progress?.sizes = Dictionary(missing.map { ($0.firmware.fileName, $0.firmware.size) },
                                         uniquingKeysWith: { a, _ in a })
            for item in items where item.onDisk { set(item.firmware, .ready(item.firmware.version)) }
            append("Plan: \(items.count) file(s), \(missing.count) to download")
        case let .warning(message):
            unseenWarnings += 1
            append("⚠︎ \(message)")
        case let .downloadStarted(fw):
            append("Downloading \(fw.fileName)")
            progress?.current = fw.fileName
            set(fw, .downloading(0))
        case let .progress(fw, received, total):
            guard status[fw.identifier] != .verifying, progress?.finished.contains(fw.fileName) != true else { return }
            progress?.received[fw.fileName] = received
            set(fw, .downloading(total > 0 ? Double(received) / Double(total) : 0))
        case let .verifying(fw):
            set(fw, .verifying)
        case let .completed(fw):
            append("Verified \(fw.fileName)")
            progress?.received[fw.fileName] = fw.size
            progress?.finished.insert(fw.fileName)
            set(fw, .ready(fw.version))
        case let .failed(fw, message):
            append("Failed \(fw.fileName): \(message)")
            progress?.finished.insert(fw.fileName)
            set(fw, .failed(message))
        case let .removed(url):
            append("Removed \(url.lastPathComponent)")
        }
    }

    private func set(_ firmware: Firmware, _ value: Status) {
        for id in modelsByFile[firmware.fileName] ?? [firmware.identifier] { status[id] = value }
    }

    private func append(_ line: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log.append("\(time)  \(line)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}
