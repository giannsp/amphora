import Foundation

public struct SyncOptions: Sendable {
    /// Model identifiers to keep current, e.g. ["iPhone16,1", "iPad14,3"].
    public var models: [String]
    /// Delete IPSWs the model list no longer needs. Only happens when every model resolved and downloaded.
    public var prune: Bool
    /// Also place verified IPSWs in Apple Configurator's cache.
    public var exportToConfigurator: Bool
    /// Report what would happen without downloading or deleting anything.
    public var dryRun: Bool
    /// Space to leave free on the store's volume.
    public var reserveBytes: Int64

    public init(models: [String], prune: Bool = true, exportToConfigurator: Bool = false,
                dryRun: Bool = false, reserveBytes: Int64 = 10 * 1_000_000_000) {
        self.models = models
        self.prune = prune
        self.exportToConfigurator = exportToConfigurator
        self.dryRun = dryRun
        self.reserveBytes = reserveBytes
    }
}

public enum SyncEvent: Sendable {
    case planned([PlannedItem])
    case warning(String)
    case downloadStarted(Firmware)
    case progress(Firmware, received: Int64, total: Int64)
    case verifying(Firmware)
    case completed(Firmware)
    case failed(Firmware, String)
    case removed(URL)
}

public struct SyncSummary: Sendable {
    public var downloaded = 0
    public var alreadyPresent = 0
    public var removed = 0
    public var problems = 0
    public var pruneSkipped = false
}

/// The whole pipeline: SOFA → firmware source → download → verify → prune.
/// Model sources (Jamf, curated list, on-demand) only decide `SyncOptions.models`.
public actor SyncEngine {
    public typealias EventHandler = @Sendable (SyncEvent) async -> Void

    let store: Store
    let sofa: SOFAClient
    let source: FirmwareSource
    let downloader: FileDownloader

    public init(store: Store, sofa: SOFAClient = SOFAClient(), source: FirmwareSource = IPSWMeSource(),
                downloader: FileDownloader = FileDownloader()) {
        self.store = store
        self.sofa = sofa
        self.source = source
        self.downloader = downloader
    }

    /// Resolves each model to the signed IPSW it needs, grouped by file. Does not touch the disk.
    public func plan(models: [String], onEvent: @escaping EventHandler) async throws -> (items: [PlannedItem], problems: Int) {
        let targets = try await sofa.fetch().targetVersions()
        var byFile: [String: (firmware: Firmware, models: [String])] = [:]
        var problems = 0

        for model in Set(models).sorted() {
            do {
                if let version = targets[model] {
                    if let firmware = try await source.signedFirmware(for: model, version: version) {
                        byFile[firmware.fileName, default: (firmware: firmware, models: [])].models.append(model)
                    } else if let firmware = try await source.latestSignedFirmware(for: model) {
                        // SOFA and Apple disagree for a moment: SOFA can lag a point release (its version is
                        // no longer signed), or list a release before its IPSW is published. Either way the
                        // newest signed release is what a restore can use right now.
                        await onEvent(.warning("\(model): \(version) isn't signed, using \(firmware.version)"))
                        byFile[firmware.fileName, default: (firmware: firmware, models: [])].models.append(model)
                    } else {
                        await onEvent(.warning("\(model): no signed IPSW for \(version) published yet"))
                        problems += 1
                    }
                } else if let firmware = try await source.latestSignedFirmware(for: model) {
                    // Dropped by current releases: keep the final version Apple still signs.
                    byFile[firmware.fileName, default: (firmware: firmware, models: [])].models.append(model)
                } else {
                    // Nothing to keep, and not an error: cleanup still runs.
                    await onEvent(.warning("\(model): Apple no longer signs any release for this model, skipped"))
                }
            } catch {
                await onEvent(.warning("\(model): lookup failed — \(error.localizedDescription)"))
                problems += 1
            }
            try await Task.sleep(nanoseconds: 300_000_000) // be polite to the firmware source
        }

        let items = byFile.values
            .map { PlannedItem(firmware: $0.firmware, models: $0.models, onDisk: store.isComplete($0.firmware)) }
            .sorted { $0.firmware.fileName < $1.firmware.fileName }
        return (items, problems)
    }

    @discardableResult
    public func sync(_ options: SyncOptions, onEvent: @escaping EventHandler) async throws -> SyncSummary {
        try store.prepare()
        var summary = SyncSummary()

        let (items, planProblems) = try await plan(models: options.models, onEvent: onEvent)
        summary.problems = planProblems
        await onEvent(.planned(items))

        let missing = items.filter { !$0.onDisk }
        summary.alreadyPresent = items.count - missing.count

        let needed = missing.reduce(Int64(0)) { $0 + $1.firmware.size - FileDownloader.size(of: store.partPath(for: $1.firmware)) }
        let available = store.availableCapacity()
        if !options.dryRun, needed + options.reserveBytes > available {
            throw MirrorError.insufficientSpace(neededBytes: needed + options.reserveBytes, availableBytes: available)
        }

        var manifest = store.readManifest()
        var exportToConfigurator = options.exportToConfigurator && !options.dryRun
        if exportToConfigurator {
            switch ConfiguratorCache.checkAccess() {
            case .granted:
                break
            case .configuratorNotFound:
                exportToConfigurator = false
                await onEvent(.warning("Apple Configurator hasn't been opened on this Mac yet. Open it once, then sync again."))
            case .denied:
                exportToConfigurator = false
                await onEvent(.warning("macOS blocks Apple Configurator's folder. Give Amphora Full Disk Access, then sync again."))
            }
        }

        for item in items {
            try Task.checkCancellation()
            let firmware = item.firmware
            var changed = false
            if !item.onDisk {
                await onEvent(.downloadStarted(firmware))
                if options.dryRun { continue }
                do {
                    try await fetch(firmware, onEvent: onEvent)
                    summary.downloaded += 1
                    changed = true
                    await onEvent(.completed(firmware))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    summary.problems += 1
                    await onEvent(.failed(firmware, error.localizedDescription))
                    continue
                }
            }
            if exportToConfigurator, store.isComplete(firmware) {
                do {
                    try ConfiguratorCache.export(store.path(for: firmware))
                    if !manifest.exportedToConfigurator.contains(firmware.fileName) {
                        manifest.exportedToConfigurator.append(firmware.fileName)
                        changed = true
                    }
                } catch {
                    await onEvent(.warning("Configurator export failed for \(firmware.fileName): \(error.localizedDescription)"))
                }
            }
            // Record each finished file right away: the app shows it as ready during the sync, and a
            // cancelled or interrupted sync doesn't forget what it already downloaded.
            if changed, !options.dryRun {
                try? store.writeManifest(updated(manifest, with: items, pruned: false))
            }
        }

        let keep = Set(items.map(\.firmware.fileName))
        if options.prune {
            if summary.problems == 0 {
                let removed = try store.prune(keeping: keep, dryRun: options.dryRun)
                    + ConfiguratorCache.prune(previouslyExported: manifest.exportedToConfigurator,
                                              keeping: keep, dryRun: options.dryRun)
                for url in removed { await onEvent(.removed(url)) }
                summary.removed = removed.count
                if !options.dryRun {
                    manifest.exportedToConfigurator.removeAll { !keep.contains($0) }
                }
            } else {
                summary.pruneSkipped = true
                await onEvent(.warning("Skipped cleanup: \(summary.problems) problem(s). Nothing usable was removed."))
            }
        }

        if !options.dryRun {
            try store.writeManifest(updated(manifest, with: items, pruned: options.prune && !summary.pruneSkipped))
        }
        return summary
    }

    private func fetch(_ firmware: Firmware, onEvent: @escaping EventHandler) async throws {
        let part = store.partPath(for: firmware)
        let digest = Checksum.digest(for: firmware)
        try await downloader.download(firmware.url, to: part, expectedSize: firmware.size,
                                      digest: digest) { received, total in
            Task { await onEvent(.progress(firmware, received: received, total: total)) }
        }

        let actual = FileDownloader.size(of: part)
        guard actual == firmware.size else {
            try? FileManager.default.removeItem(at: part)
            throw MirrorError.sizeMismatch(firmware.fileName, expected: firmware.size, actual: actual)
        }

        await onEvent(.verifying(firmware))
        // Hashed during the download. Should that not cover exactly the file on disk, read it back instead.
        let verified: Bool
        if let digest, digest.byteCount == actual {
            verified = digest.matches
        } else {
            verified = try Checksum.verify(part, against: firmware)
        }
        guard verified else {
            try? FileManager.default.removeItem(at: part)
            throw MirrorError.checksumMismatch(firmware.fileName)
        }

        let destination = store.path(for: firmware)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: part, to: destination)
    }

    /// After a full sync the manifest is exactly the plan; after a partial or on-demand run,
    /// earlier entries whose files still exist are kept.
    private func updated(_ manifest: Manifest, with items: [PlannedItem], pruned: Bool) -> Manifest {
        let fresh = items
            .filter { store.isComplete($0.firmware) }
            .map { Manifest.Entry(file: $0.firmware.fileName, version: $0.firmware.version,
                                  build: $0.firmware.build, models: $0.models, sha256: $0.firmware.sha256) }
        var entries = fresh
        if !pruned {
            let freshFiles = Set(fresh.map(\.file))
            let freshModels = Set(fresh.flatMap(\.models))
            for old in manifest.entries where !freshFiles.contains(old.file) {
                let stillThere = FileManager.default.fileExists(atPath: store.root.appendingPathComponent(old.file).path)
                let models = old.models.filter { !freshModels.contains($0) }
                if stillThere, !models.isEmpty {
                    entries.append(.init(file: old.file, version: old.version, build: old.build,
                                         models: models, sha256: old.sha256))
                }
            }
        }
        var result = manifest
        result.generated = Date()
        result.entries = entries.sorted { $0.file < $1.file }
        return result
    }
}
