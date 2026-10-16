import AppKit
import Foundation
import AmphoraCore
import Observation
import ServiceManagement

/// App state. Settings live in the app's defaults domain (consulting.techne.amphora),
/// so a configuration profile can set them without code changes.
@MainActor
@Observable
final class AppModel {
    struct Row: Identifiable, Hashable {
        let device: DeviceModel
        let targetVersion: String
        /// Dropped by current releases; kept on the final version Apple still signs.
        var isLegacy = false
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
        /// Always the finished file name ("…_Restore.ipsw"), also for a partial download.
        let name: String
        let size: Int64
        let version: String?
        let models: [String]
        /// A download that hasn't finished: only the .ipsw.part file exists.
        let isPartial: Bool
        var id: String { name }
    }

    /// Apple names restore files "<model>[,<model>…]_<version>_<build>_Restore.ipsw",
    /// e.g. "iPad14,3,iPad14,4_27.0.1_24A446_Restore.ipsw".
    static func parse(fileName: String) -> (models: [String], version: String?) {
        let parts = fileName.split(separator: "_")
        guard let head = parts.first else { return ([], nil) }
        let regex = #/(iPhone|iPad)\d+,\d+/#
        let models = head.matches(of: regex).map { String($0.output.0) }
        return (models, parts.dropFirst().first.map(String.init))
    }

    static let syncIntervalChoices = [1, 3, 6, 12, 24]

    /// Where the list of models to keep current comes from.
    enum ModelSource: String, CaseIterable, Identifiable {
        case curated, jamf
        var id: String { rawValue }
        var title: String { self == .curated ? "Models I choose" : "Jamf Pro inventory" }
    }

    private enum Key {
        static let selected = "SelectedModels"
        static let storePath = "StorePath"
        static let prune = "PruneOldIPSWs"
        static let configurator = "ExportToConfigurator"
        static let setupDismissed = "ConfiguratorSetupDismissed"
        static let lastSync = "LastSync"
        static let source = "ModelSource"
        static let jamfURL = "JamfURL"
        static let jamfClientID = "JamfClientID"
        static let jamfManagedOnly = "JamfManagedDevicesOnly"
        static let jamfCounts = "JamfLastInventory"
        static let jamfFetched = "JamfLastInventoryDate"
        static let jamfGraceDays = "JamfRemovedModelGraceDays"
        static let legacyTargets = "LegacyModelVersions"
        static let syncHours = "SyncIntervalHours"
        static let showInMenuBar = "ShowInMenuBar"
        static let loginItemOffered = "LoginItemOffered"
        static let onboardingCompleted = "OnboardingCompleted"
        static let notify = "NotifyNewReleases"
    }

    private let defaults = UserDefaults.standard

    /// Models current releases support (from SOFA).
    private var sofaRows: [Row] = []
    /// Jamf models current releases dropped → final version Apple still signs.
    var legacyTargets: [String: String] {
        didSet { defaults.set(legacyTargets, forKey: Key.legacyTargets) }
    }
    var rows: [Row] {
        guard modelSource == .jamf else { return sofaRows }
        let known = Set(sofaRows.map(\.id))
        let legacy = legacyTargets
            .filter { !known.contains($0.key) && jamfModelIDs.contains($0.key) }
            .map { Row(device: DeviceModel(identifier: $0.key, name: deviceNames[$0.key] ?? $0.key),
                       targetVersion: $0.value, isLegacy: true) }
        return sofaRows + legacy
    }
    /// Marketing names for every iPhone/iPad identifier, including models no current release supports.
    var deviceNames: [String: String] = [:]
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
        didSet { defaults.set(storePath, forKey: Key.storePath); loadRetained(); refreshStatus() }
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

    // Jamf Pro
    var modelSource: ModelSource {
        didSet { defaults.set(modelSource.rawValue, forKey: Key.source) }
    }
    var jamfURL: String {
        didSet { defaults.set(jamfURL, forKey: Key.jamfURL) }
    }
    var jamfClientID: String {
        didSet {
            defaults.set(jamfClientID, forKey: Key.jamfClientID)
            jamfSecretSaved = Keychain.secret(for: jamfClientID) != nil
        }
    }
    var jamfManagedOnly: Bool {
        didSet { defaults.set(jamfManagedOnly, forKey: Key.jamfManagedOnly) }
    }
    /// Last successful inventory, kept so the app still knows the fleet when Jamf is unreachable.
    /// Days a model's file stays after the model leaves Jamf Pro (0: delete at the next sync).
    var jamfGraceDays: Int {
        didSet { defaults.set(jamfGraceDays, forKey: Key.jamfGraceDays); loadRetained() }
    }
    var jamfGraceDaysManaged: Bool { defaults.objectIsForced(forKey: Key.jamfGraceDays) }
    /// Models no longer in Jamf Pro whose file is kept until the date shown.
    var jamfRetained: [String: Date] = [:]
    /// Every model the Jamf fleet needs: the inventory, plus models within their grace period.
    var jamfModelIDs: Set<String> { Set(jamfCounts.keys).union(jamfRetained.keys) }

    var jamfCounts: [String: Int] {
        didSet { defaults.set(jamfCounts, forKey: Key.jamfCounts) }
    }
    var jamfFetched: Date? {
        didSet { defaults.set(jamfFetched, forKey: Key.jamfFetched) }
    }
    var jamfError: String?

    // Background
    /// Hours between automatic syncs.
    var syncIntervalHours: Int {
        didSet { defaults.set(syncIntervalHours, forKey: Key.syncHours) }
    }
    var syncInterval: TimeInterval { TimeInterval(max(1, syncIntervalHours)) * 3600 }
    /// Keep running in the menu bar when the window is closed.
    var showInMenuBar: Bool {
        didSet { defaults.set(showInMenuBar, forKey: Key.showInMenuBar) }
    }
    var loginItemStatus: SMAppService.Status = SMAppService.mainApp.status
    /// The first-launch setup assistant.
    var showOnboarding = false
    /// Post a notification when new restore files are ready, or downloads fail.
    var notify: Bool {
        didSet { defaults.set(notify, forKey: Key.notify) }
    }
    private var runDownloads: [(firmware: Firmware, models: [String])] = []
    private var runFailures = 0
    private var userCancelled = false
    var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }
    var loginItemError: String?
    private var schedulerTask: Task<Void, Never>?
    var jamfSecretSaved = false
    var isFetchingJamf = false

    init() {
        Migration.runIfNeeded()
        selected = Set(defaults.stringArray(forKey: Key.selected) ?? [])
        storePath = defaults.string(forKey: Key.storePath) ?? Store.defaultRoot.path
        prune = defaults.object(forKey: Key.prune) as? Bool ?? true
        exportToConfigurator = defaults.object(forKey: Key.configurator) as? Bool ?? true
        configuratorSetupDismissed = defaults.bool(forKey: Key.setupDismissed)
        lastSync = defaults.object(forKey: Key.lastSync) as? Date
        modelSource = ModelSource(rawValue: defaults.string(forKey: Key.source) ?? "") ?? .curated
        jamfURL = defaults.string(forKey: Key.jamfURL) ?? ""
        jamfClientID = defaults.string(forKey: Key.jamfClientID) ?? ""
        jamfManagedOnly = defaults.object(forKey: Key.jamfManagedOnly) as? Bool ?? true
        jamfCounts = defaults.dictionary(forKey: Key.jamfCounts) as? [String: Int] ?? [:]
        jamfFetched = defaults.object(forKey: Key.jamfFetched) as? Date
        jamfGraceDays = max(0, defaults.object(forKey: Key.jamfGraceDays) as? Int ?? ModelRetention.defaultGraceDays)
        legacyTargets = defaults.dictionary(forKey: Key.legacyTargets) as? [String: String] ?? [:]
        syncIntervalHours = defaults.object(forKey: Key.syncHours) as? Int ?? 6
        showInMenuBar = defaults.object(forKey: Key.showInMenuBar) as? Bool ?? true
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        notify = defaults.object(forKey: Key.notify) as? Bool ?? true
        jamfSecretSaved = !jamfClientID.isEmpty && Keychain.secret(for: jamfClientID) != nil
        loadRetained()
    }

    /// Reads which removed models are still within their grace period, from the store's history.
    func loadRetained() {
        jamfRetained = store.readRetention().retained(excluding: Set(jamfCounts.keys), graceDays: jamfGraceDays)
    }

    // MARK: Derived

    var store: Store { Store(root: URL(fileURLWithPath: storePath, isDirectory: true)) }

    /// True when a configuration profile sets the value, so the UI shows it locked.
    var storePathManaged: Bool { defaults.objectIsForced(forKey: Key.storePath) }
    var selectionManaged: Bool { defaults.objectIsForced(forKey: Key.selected) }
    var sourceManaged: Bool { defaults.objectIsForced(forKey: Key.source) }
    var jamfURLManaged: Bool { defaults.objectIsForced(forKey: Key.jamfURL) }
    var jamfClientIDManaged: Bool { defaults.objectIsForced(forKey: Key.jamfClientID) }

    /// Models kept current: ticked by hand, or every model in Jamf that a current iOS/iPadOS supports.
    var keptIDs: Set<String> {
        switch modelSource {
        case .curated: return selected
        case .jamf: return jamfModelIDs.intersection(rows.map(\.id))
        }
    }

    func isKept(_ id: String) -> Bool { keptIDs.contains(id) }

    /// Ticking is off when a profile sets the list or Jamf supplies it.
    var selectionLocked: Bool { selectionManaged || modelSource == .jamf }
    var selectionLockReason: String? {
        if modelSource == .jamf { return "Kept current because it's in your Jamf Pro inventory" }
        if selectionManaged { return "Set by your organization" }
        return nil
    }

    /// Models in Jamf that no current iOS/iPadOS supports (old devices): nothing to download for them.
    var jamfUnsupported: [String] {
        guard !rows.isEmpty else { return [] }
        let known = Set(rows.map(\.id))
        return jamfCounts.keys.filter { !known.contains($0) }.sorted()
    }

    var jamfConfigured: Bool { !jamfURL.isEmpty && !jamfClientID.isEmpty && jamfSecretSaved }

    func saveJamfSecret(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !jamfClientID.isEmpty else { return }
        do {
            try Keychain.setSecret(trimmed, for: jamfClientID)
            jamfSecretSaved = true
        } catch {
            jamfError = "Couldn't save the secret in the Keychain. \(error.localizedDescription)"
        }
    }

    /// Called by the setup assistant's last step.
    func completeOnboarding(openAtLogin wantsLogin: Bool) {
        if wantsLogin != openAtLogin { setOpenAtLogin(wantsLogin) }
        defaults.set(true, forKey: Key.loginItemOffered)
        configuratorSetupDismissed = true   // Full Disk Access was covered in the assistant
        onboardingCompleted = true
        showOnboarding = false
    }

    /// For Jamf models current releases dropped, finds the final version Apple still signs.
    /// A model with nothing signed stays out of the list (shown as "No signed release").
    func resolveLegacyModels() async {
        guard !sofaRows.isEmpty else { return }
        let known = Set(sofaRows.map(\.id))
        var resolved: [String: String] = [:]
        for id in jamfModelIDs.sorted() where !known.contains(id) {
            do {
                if let firmware = try await IPSWMeSource().latestSignedFirmware(for: id) {
                    resolved[id] = firmware.version
                }
            } catch {
                // Lookup failed (offline?): keep what we knew rather than call the model unsupported.
                if let known = legacyTargets[id] { resolved[id] = known }
            }
        }
        legacyTargets = resolved
        refreshStatus()
    }

    /// Fetches the inventory. On failure the last good inventory stays in use and nothing is pruned on its account.
    @discardableResult
    func refreshJamf() async -> Bool {
        guard jamfConfigured, !isFetchingJamf else {
            if !jamfConfigured { jamfError = "Add your Jamf Pro address, client ID and secret in Settings." }
            return false
        }
        isFetchingJamf = true
        defer { isFetchingJamf = false }
        do {
            guard let secret = Keychain.secret(for: jamfClientID) else {
                jamfSecretSaved = false
                throw JamfClient.JamfError.badCredentials
            }
            let credentials = JamfClient.Credentials(url: try JamfClient.normalizedURL(jamfURL),
                                                     clientID: jamfClientID, clientSecret: secret)
            let inventory = try await JamfClient(credentials: credentials).inventory(managedOnly: jamfManagedOnly)
            jamfCounts = inventory.counts
            jamfFetched = inventory.fetched
            // A model that just left Jamf Pro keeps its file for a while (ModelRetention).
            var retention = store.readRetention()
            jamfRetained = retention.record(inventory: Set(inventory.counts.keys), graceDays: jamfGraceDays)
            try? store.writeRetention(retention)
            jamfError = nil
            append("Jamf Pro: \(plural(inventory.deviceCount, "device")), \(plural(inventory.counts.count, "model"))")
            await resolveLegacyModels()
            return true
        } catch {
            jamfError = error.localizedDescription
            unseenWarnings += 1
            append("⚠︎ Jamf Pro: \(error.localizedDescription)")
            return false
        }
    }
    var configuratorManaged: Bool { defaults.objectIsForced(forKey: Key.configurator) }

    /// True when the export is on but macOS (or a missing Configurator) stops it.
    var configuratorBlocked: Bool {
        exportToConfigurator && configuratorAccess != nil && configuratorAccess != .granted
    }

    func checkConfiguratorAccess() {
        configuratorAccess = exportToConfigurator ? ConfiguratorCache.checkAccess() : nil
    }

    var keptRows: [Row] { rows.filter { keptIDs.contains($0.id) } }
    var readyCount: Int { keptRows.filter { status[$0.id]?.isReady == true }.count }
    var failedCount: Int { keptRows.filter { status[$0.id]?.isFailed == true }.count }
    var attentionRows: [Row] { keptRows.filter { status[$0.id]?.isReady != true } }
    var nextSync: Date? { lastSync?.addingTimeInterval(syncInterval) }

    /// Menu bar icon: what state the restore files are in, at a glance.
    /// Something that needs the user: failed downloads, no access to Configurator's cache, or Jamf Pro errors.
    var needsAttention: Bool {
        failedCount > 0 || configuratorBlocked || (modelSource == .jamf && jamfError != nil)
    }

    /// How full the menu bar amphora is: the share of your models that are ready to restore.
    /// During a sync, bytes downloaded for the missing ones count too, so the jar visibly fills.
    var menuBarFill: Double {
        let kept = keptRows.count
        guard kept > 0 else { return 0 }
        let ready = Double(readyCount)
        guard isBusy, let progress, progress.fileCount > 0 else { return ready / Double(kept) }
        return min(1, (ready + progress.fraction * Double(kept - readyCount)) / Double(kept))
    }

    var menuBarIcon: NSImage {
        MenuBarIcon.image(fill: menuBarFill, badge: needsAttention && !isBusy ? .attention : .none)
    }

    var isSyncDue: Bool {
        guard let lastSync else { return true }
        return Date().timeIntervalSince(lastSync) >= syncInterval
    }

    // MARK: Background

    /// Runs for the life of the app, window or not: syncs at launch when due, then whenever the interval passes.
    /// Checks every 15 minutes, so a Mac that slept through a due time catches up soon after waking.
    func startScheduler() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task { [self] in
            await load()
            var releasesFresh = true
            while !Task.isCancelled {
                let hasModels = onboardingCompleted && (modelSource == .jamf ? jamfConfigured : !selected.isEmpty)
                if hasModels && isSyncDue && !isBusy {
                    if !releasesFresh { await load() }   // pick up releases published since the last check
                    await syncSelected()
                }
                releasesFresh = false
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    var openAtLogin: Bool { loginItemStatus == .enabled || loginItemStatus == .requiresApproval }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        loginItemStatus = SMAppService.mainApp.status
    }

    /// The first launch turns on Open at Login, since a service desk tool must survive reboots.
    /// macOS tells the user it added a login item; the setting is in Settings › Background.
    func registerLoginItemOnFirstLaunch() {
        loginItemStatus = SMAppService.mainApp.status
        guard onboardingCompleted, !defaults.bool(forKey: Key.loginItemOffered) else { return }
        defaults.set(true, forKey: Key.loginItemOffered)
        if loginItemStatus != .enabled { setOpenAtLogin(true) }
    }

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
            if !names.isEmpty { deviceNames = names }
            sofaRows = targets
                .map { Row(device: DeviceModel(identifier: $0.key, name: names[$0.key] ?? $0.key), targetVersion: $0.value) }
                .sorted { $0.device.identifier.localizedStandardCompare($1.device.identifier) == .orderedDescending }
            lastError = nil
            refreshStatus()
        } catch {
            lastError = "Couldn't load current releases from SOFA. \(error.localizedDescription)"
        }
        if modelSource == .jamf && jamfConfigured { await refreshJamf() }
    }

    func refreshStatus() {
        let manifest = store.readManifest()
        let entries = Dictionary(manifest.entries.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
        var byName: [String: StoredFile] = [:]
        for url in store.ipswFiles() {
            let isPartial = url.pathExtension == "part"
            let name = isPartial ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
            if isPartial, byName[name] != nil { continue }   // a finished file wins over a leftover partial
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let parsed = Self.parse(fileName: name)
            let entry = isPartial ? nil : entries[name]
            byName[name] = StoredFile(name: name, size: Int64(size),
                                      version: entry?.version ?? parsed.version,
                                      models: entry?.models ?? parsed.models,
                                      isPartial: isPartial)
        }
        storedFiles = byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let onDisk = manifest.versionsByModel()
        for row in rows {
            switch status[row.id] {
            case .downloading, .verifying, .queued: continue
            default: break
            }
            if let version = onDisk[row.id] {
                // Newer than SOFA's version counts as ready: SOFA can lag a point release that Apple already signs.
                let current = version.compare(row.targetVersion, options: .numeric) != .orderedAscending
                status[row.id] = current ? .ready(version) : .outdated(version)
            } else if status[row.id]?.isFailed != true {
                status[row.id] = .missing
            }
        }
    }

    // MARK: Manual deletion

    func displayName(_ identifier: String) -> String {
        rows.first { $0.id == identifier }?.device.name ?? deviceNames[identifier] ?? identifier
    }

    /// Any file for the model, finished or partial: what Delete acts on.
    func fileName(for identifier: String) -> String? {
        storedFiles.first { $0.models.contains(identifier) }?.name
    }

    func hasPartialFile(for identifier: String) -> Bool {
        storedFiles.first { $0.models.contains(identifier) }?.isPartial == true
    }

    /// The finished IPSW for a model, for drag-to-restore and Show in Finder. Never a partial.
    func fileURL(for identifier: String) -> URL? {
        storedFiles.first { $0.models.contains(identifier) && !$0.isPartial }
            .map { store.root.appendingPathComponent($0.name) }
    }

    /// Allowed during a sync too: confirming stops the sync first, so a file being written is never pulled out from under it.
    func requestDelete(_ names: Set<String>) {
        guard !names.isEmpty else { return }
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
        pendingFiles.flatMap(\.models).filter { keptIDs.contains($0) }
    }

    var deletionTitle: String {
        let files = pendingFiles
        if files.count == 1, files[0].isPartial { return "Delete the partial download?" }
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
            text += " \(nameList(kept)) \(kept.count == 1 ? "is" : "are") in My Devices, "
                + "so the next sync downloads \(files.count == 1 ? "it" : "them") again."
        }
        if isBusy { text += " The sync in progress stops first." }
        return text
    }

    /// Called by the confirmation's button. Takes what to delete *now*: closing the dialog clears
    /// `pendingDeletion` straight after, before any async work could read it.
    func confirmDelete(stopKeeping: Bool) {
        guard let names = pendingDeletion else { return }
        let models = pendingFiles.flatMap(\.models)
        pendingDeletion = nil
        Task { await delete(names, models: models, stopKeeping: stopKeeping) }
    }

    private func delete(_ names: Set<String>, models: [String], stopKeeping: Bool) async {
        if isBusy {
            append("Stopping the sync to delete files")
            cancel()
            while isBusy { try? await Task.sleep(for: .milliseconds(100)) }
        }
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
        guard !isBusy else { return }
        if modelSource == .jamf { await refreshJamf() }
        let models = keptIDs
        guard !models.isEmpty else { return }
        await run(SyncOptions(models: Array(models), prune: prune, exportToConfigurator: exportToConfigurator))
        lastSync = Date()
    }

    func downloadNow(_ identifier: String) async {
        await run(SyncOptions(models: [identifier], prune: false, exportToConfigurator: exportToConfigurator))
    }

    func cancel() {
        userCancelled = true
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
        runDownloads = []
        runFailures = 0
        userCancelled = false
        for id in options.models { status[id] = .queued }

        let engine = SyncEngine(store: store)
        // Don't let idle sleep cut a 12 GB download short. The display may still sleep.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Downloading IPSW files")
        defer { ProcessInfo.processInfo.endActivity(activity) }
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

        if notify {
            Notifier.shared.announceReady(runDownloads, name: displayName)
            if !userCancelled { Notifier.shared.announceFailures(runFailures) }
        }
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
            // Make the new partial file visible (Downloaded pane, Delete in the model's menu) as soon as it exists.
            if !storedFiles.contains(where: { $0.name == fw.fileName }) { refreshStatus() }
            progress?.received[fw.fileName] = received
            set(fw, .downloading(total > 0 ? Double(received) / Double(total) : 0))
        case let .verifying(fw):
            set(fw, .verifying)
        case let .completed(fw):
            append("Verified \(fw.fileName)")
            progress?.received[fw.fileName] = fw.size
            progress?.finished.insert(fw.fileName)
            set(fw, .ready(fw.version))
            runDownloads.append((fw, modelsByFile[fw.fileName] ?? [fw.identifier]))
        case let .failed(fw, message):
            append("Failed \(fw.fileName): \(message)")
            runFailures += 1
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
