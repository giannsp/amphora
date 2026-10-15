import Foundation
import AmphoraCore

let usage = """
amphora \(AppInfo.version) — keep the latest signed iOS/iPadOS IPSWs on disk

USAGE
  amphora sync   --models <id,id,...> [--store <dir>] [--no-prune] [--configurator] [--dry-run]
  amphora sync   --from-jamf          [--include-unmanaged] [same options as above]
  amphora jamf   [--include-unmanaged]
  amphora get    <model-identifier>   [--store <dir>] [--configurator]
  amphora plan   --models <id,id,...> [--store <dir>]
  amphora models [--filter <text>]

  sync    Download what the model list needs, then delete IPSWs it no longer needs.
          Cleanup only runs when every model resolved and downloaded.
  get     Download one model's IPSW now. Deletes nothing.
  plan    Show which files the model list needs and what is already on disk.
  models  List current model identifiers with names and target versions.
  jamf    Show which models Jamf Pro holds, with device counts.

  Jamf Pro: set JAMF_URL and JAMF_CLIENT_ID, and JAMF_CLIENT_SECRET (or save the secret
  once in the app, which keeps it in the Keychain). The API role needs Read Mobile Devices.

  --store defaults to "\(Store.defaultRoot.path)". Use a dedicated folder:
  sync deletes any .ipsw in it that the model list does not need.
"""

struct Arguments {
    var command = ""
    var positional: [String] = []
    var models: [String] = []
    var store = Store.defaultRoot
    var prune = true
    var configurator = false
    var dryRun = false
    var filter: String?
    var fromJamf = false
    var includeUnmanaged = false

    init(_ argv: [String]) throws {
        var it = argv.makeIterator()
        command = it.next() ?? ""
        while let arg = it.next() {
            switch arg {
            case "--models":
                models = DeviceModel.identifiers(in: it.next() ?? "")
                    .filter { !$0.isEmpty }
            case "--store":
                guard let path = it.next() else { throw ArgumentError("--store needs a folder") }
                store = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            case "--no-prune": prune = false
            case "--configurator": configurator = true
            case "--dry-run": dryRun = true
            case "--filter": filter = it.next()
            case "--from-jamf": fromJamf = true
            case "--include-unmanaged": includeUnmanaged = true
            case "-h", "--help": command = "help"
            default:
                guard !arg.hasPrefix("-") else { throw ArgumentError("Unknown option \(arg)") }
                positional.append(arg)
            }
        }
    }
}

struct ArgumentError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func gb(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("\(stamp)  \(message)")
}

let printEvent: SyncEngine.EventHandler = { event in
    switch event {
    case let .planned(items):
        let missing = items.filter { !$0.onDisk }
        log("Plan: \(items.count) file(s), \(missing.count) to download (\(gb(missing.reduce(0) { $0 + $1.firmware.size })))")
    case let .warning(message):
        log("WARN  \(message)")
    case let .downloadStarted(fw):
        log("GET   \(fw.fileName) (\(gb(fw.size)))")
    case let .progress(fw, received, total):
        let pct = total > 0 ? Int(Double(received) / Double(total) * 100) : 0
        FileHandle.standardError.write(Data("\r      \(fw.fileName) \(pct)%   ".utf8))
    case let .verifying(fw):
        FileHandle.standardError.write(Data("\n".utf8))
        log("SHA   \(fw.fileName)")
    case let .completed(fw):
        log("DONE  \(fw.fileName)")
    case let .failed(fw, message):
        log("FAIL  \(fw.fileName): \(message)")
    case let .removed(url):
        log("DEL   \(url.lastPathComponent)")
    }
}

func jamfCredentials() throws -> JamfClient.Credentials {
    let env = ProcessInfo.processInfo.environment
    guard let urlText = env["JAMF_URL"], let clientID = env["JAMF_CLIENT_ID"] else {
        throw ArgumentError("Set JAMF_URL and JAMF_CLIENT_ID (and JAMF_CLIENT_SECRET) to use Jamf Pro.")
    }
    guard let secret = env["JAMF_CLIENT_SECRET"] ?? Keychain.secret(for: clientID) else {
        throw ArgumentError("No client secret: set JAMF_CLIENT_SECRET or save it once in the app.")
    }
    return .init(url: try JamfClient.normalizedURL(urlText), clientID: clientID, clientSecret: secret)
}

func run() async -> Int32 {
    let args: Arguments
    do {
        args = try Arguments(Array(CommandLine.arguments.dropFirst()))
    } catch {
        print(error.localizedDescription, usage, separator: "\n\n")
        return 2
    }

    let engine = SyncEngine(store: Store(root: args.store))

    do {
        switch args.command {
        case "sync":
            var models = args.models
            if args.fromJamf {
                let inventory = try await JamfClient(credentials: try jamfCredentials())
                    .inventory(managedOnly: !args.includeUnmanaged)
                models = Array(inventory.counts.keys)
                log("Jamf Pro: \(inventory.deviceCount) devices, \(models.count) models")
            }
            guard !models.isEmpty else { print("sync needs --models or --from-jamf\n\n\(usage)"); return 2 }
            if args.dryRun { log("Dry run: nothing will be downloaded or deleted") }
            let summary = try await engine.sync(
                SyncOptions(models: models, prune: args.prune,
                            exportToConfigurator: args.configurator, dryRun: args.dryRun),
                onEvent: printEvent)
            log("Finished: \(summary.downloaded) downloaded, \(summary.alreadyPresent) already present, "
                + "\(summary.removed) removed, \(summary.problems) problem(s)")
            return summary.problems == 0 ? 0 : 1

        case "get":
            guard let model = args.positional.first else { print("get needs a model identifier\n\n\(usage)"); return 2 }
            let summary = try await engine.sync(
                SyncOptions(models: [model], prune: false, exportToConfigurator: args.configurator),
                onEvent: printEvent)
            return summary.problems == 0 ? 0 : 1

        case "plan":
            guard !args.models.isEmpty else { print("plan needs --models\n\n\(usage)"); return 2 }
            let (items, problems) = try await engine.plan(models: args.models, onEvent: printEvent)
            for item in items {
                let state = item.onDisk ? "on disk " : "missing "
                print("\(state) \(item.firmware.version.padding(toLength: 8, withPad: " ", startingAt: 0)) "
                      + "\(gb(item.firmware.size).padding(toLength: 9, withPad: " ", startingAt: 0)) "
                      + "\(item.firmware.fileName)  ← \(item.models.joined(separator: ", "))")
            }
            return problems == 0 ? 0 : 1

        case "jamf":
            let inventory = try await JamfClient(credentials: try jamfCredentials())
                .inventory(managedOnly: !args.includeUnmanaged)
            for (id, count) in inventory.counts.sorted(by: { $0.value > $1.value }) {
                print("\(id.padding(toLength: 12, withPad: " ", startingAt: 0)) \(count)")
            }
            print("\(inventory.deviceCount) devices, \(inventory.counts.count) models")
            return 0

        case "models":
            async let feed = SOFAClient().fetch()
            async let names = IPSWMeSource().devices()
            let targets = try await feed.targetVersions()
            let devices = try await names
            let byID = Dictionary(devices.map { ($0.identifier, $0.name) }, uniquingKeysWith: { a, _ in a })
            let filter = args.filter?.lowercased()
            for id in targets.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let name = byID[id] ?? id
                if let filter, !name.lowercased().contains(filter), !id.lowercased().contains(filter) { continue }
                print("\(id.padding(toLength: 12, withPad: " ", startingAt: 0)) "
                      + "\(targets[id]!.padding(toLength: 8, withPad: " ", startingAt: 0)) \(name)")
            }
            return 0

        default:
            print(usage)
            return args.command == "help" ? 0 : 2
        }
    } catch {
        log("ERROR \(error.localizedDescription)")
        return 1
    }
}

exit(await run())
