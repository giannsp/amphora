import Foundation
import IPSWMirrorCore

let usage = """
ipsw-mirror \(IPSWMirror.version) — keep the latest signed iOS/iPadOS IPSWs on disk

USAGE
  ipsw-mirror sync   --models <id,id,...> [--store <dir>] [--no-prune] [--configurator] [--dry-run]
  ipsw-mirror get    <model-identifier>   [--store <dir>] [--configurator]
  ipsw-mirror plan   --models <id,id,...> [--store <dir>]
  ipsw-mirror models [--filter <text>]

  sync    Download what the model list needs, then delete IPSWs it no longer needs.
          Cleanup only runs when every model resolved and downloaded.
  get     Download one model's IPSW now. Deletes nothing.
  plan    Show which files the model list needs and what is already on disk.
  models  List current model identifiers with names and target versions.

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

    init(_ argv: [String]) throws {
        var it = argv.makeIterator()
        command = it.next() ?? ""
        while let arg = it.next() {
            switch arg {
            case "--models":
                models = (it.next() ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "--store":
                guard let path = it.next() else { throw ArgumentError("--store needs a folder") }
                store = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            case "--no-prune": prune = false
            case "--configurator": configurator = true
            case "--dry-run": dryRun = true
            case "--filter": filter = it.next()
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
            guard !args.models.isEmpty else { print("sync needs --models\n\n\(usage)"); return 2 }
            if args.dryRun { log("Dry run: nothing will be downloaded or deleted") }
            let summary = try await engine.sync(
                SyncOptions(models: args.models, prune: args.prune,
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
