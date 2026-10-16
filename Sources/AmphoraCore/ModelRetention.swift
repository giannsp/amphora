import Foundation

/// When each Jamf Pro model was last in the inventory. A model that leaves Jamf Pro keeps its restore
/// file for a grace period, so deleting a device record before restoring the device doesn't also delete
/// the file you're about to need. Stored next to the IPSWs in `<store>/.state/jamf-models.json`.
public struct ModelRetention: Codable, Sendable, Equatable {
    public static let defaultGraceDays = 14

    /// Model identifier → last time an inventory contained it.
    public var lastSeen: [String: Date]

    public init(lastSeen: [String: Date] = [:]) {
        self.lastSeen = lastSeen
    }

    /// Records a fresh inventory: every model in it is seen now, and models gone longer than the grace
    /// period are forgotten. Returns the models still kept although Jamf Pro no longer has them,
    /// with the moment each one's file becomes deletable. `graceDays` of 0 keeps nothing.
    @discardableResult
    public mutating func record(inventory models: Set<String>, graceDays: Int, now: Date = Date()) -> [String: Date] {
        for model in models { lastSeen[model] = now }
        let kept = retained(excluding: models, graceDays: graceDays, now: now)
        lastSeen = lastSeen.filter { models.contains($0.key) || kept[$0.key] != nil }
        return kept
    }

    /// Models not in `models` whose grace period hasn't ended, with the end of it. Changes nothing.
    public func retained(excluding models: Set<String>, graceDays: Int, now: Date = Date()) -> [String: Date] {
        guard graceDays > 0 else { return [:] }
        var kept: [String: Date] = [:]
        for (model, seen) in lastSeen where !models.contains(model) {
            let until = seen.addingTimeInterval(TimeInterval(graceDays) * 86_400)
            if until > now { kept[model] = until }
        }
        return kept
    }
}

extension Store {
    var retentionURL: URL { stateDirectory.appendingPathComponent("jamf-models.json") }

    public func readRetention() -> ModelRetention {
        guard let data = try? Data(contentsOf: retentionURL) else { return ModelRetention() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ModelRetention.self, from: data)) ?? ModelRetention()
    }

    public func writeRetention(_ retention: ModelRetention) throws {
        try prepare()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(retention).write(to: retentionURL, options: .atomic)
    }
}
