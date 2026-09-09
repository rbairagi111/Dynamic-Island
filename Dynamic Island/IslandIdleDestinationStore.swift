import Foundation
import Combine

/// Local usage scores for idle destinations. No browsing history — only the fixed catalog.
final class IslandIdleDestinationStore: ObservableObject {
    static let shared = IslandIdleDestinationStore()

    private enum Keys {
        static let stats = "islandIdleDestinationStats.v1"
    }

    struct Entry: Codable, Equatable {
        var count: Int
        var lastOpenedAt: Date?
    }

    @Published private(set) var ranked: [IslandIdleDestination]

    private var stats: [IslandIdleDestination: Entry]
    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        self.stats = Self.load(defaults: defaults)
        self.ranked = IslandIdleDestinationRanker.ranked(
            stats: stats.mapValues { ($0.count, $0.lastOpenedAt) },
            now: now()
        )
    }

    func record(_ destination: IslandIdleDestination) {
        var entry = stats[destination] ?? Entry(count: 0, lastOpenedAt: nil)
        entry.count += 1
        entry.lastOpenedAt = now()
        stats[destination] = entry
        persist()
        ranked = IslandIdleDestinationRanker.ranked(
            stats: stats.mapValues { ($0.count, $0.lastOpenedAt) },
            now: now()
        )
    }

    /// Refresh ranking without a new open (e.g. after clock change / wake).
    func refreshRanking() {
        ranked = IslandIdleDestinationRanker.ranked(
            stats: stats.mapValues { ($0.count, $0.lastOpenedAt) },
            now: now()
        )
    }

    private func persist() {
        let payload = Dictionary(uniqueKeysWithValues: stats.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: Keys.stats)
        }
    }

    private static func load(defaults: UserDefaults) -> [IslandIdleDestination: Entry] {
        guard let data = defaults.data(forKey: Keys.stats),
              let raw = try? JSONDecoder().decode([String: Entry].self, from: data)
        else {
            return [:]
        }
        var result: [IslandIdleDestination: Entry] = [:]
        for (key, value) in raw {
            guard let destination = IslandIdleDestination(rawValue: key) else { continue }
            result[destination] = value
        }
        return result
    }
}
