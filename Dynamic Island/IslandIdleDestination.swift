import Foundation

/// Fixed catalog of idle-glance destinations (AI chats + YouTube family).
/// Not a general app launcher — only surfaces this island already understands.
enum IslandIdleDestination: String, CaseIterable, Codable, Equatable, Hashable {
    case youtube
    case youtubeMusic
    case claude
    case chatgpt
    case gemini

    var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .youtubeMusic: return "YouTube Music"
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .gemini: return "Gemini"
        }
    }

    var homeURL: URL {
        switch self {
        case .youtube: return URL(string: "https://www.youtube.com")!
        case .youtubeMusic: return URL(string: "https://music.youtube.com")!
        case .claude: return URL(string: "https://claude.ai")!
        case .chatgpt: return URL(string: "https://chatgpt.com")!
        case .gemini: return URL(string: "https://gemini.google.com")!
        }
    }

    /// Bundled official marks — YouTube play badge vs YouTube Music play-circle.
    var logoAssetName: String? {
        switch self {
        case .youtube: return "YouTubeOfficialLogo"
        case .youtubeMusic: return "YouTubeMusicOfficialLogo"
        case .claude: return "ClaudeLogo"
        case .chatgpt: return "ChatGPTLogo"
        case .gemini: return "GeminiLogo"
        }
    }

    var systemImageName: String {
        switch self {
        case .youtube: return "play.rectangle.fill"
        case .youtubeMusic: return "music.note"
        case .claude, .chatgpt, .gemini: return "bubble.left.and.bubble.right.fill"
        }
    }

    func matches(url: String) -> Bool {
        Self.from(url: url) == self
    }

    static func from(url: String) -> IslandIdleDestination? {
        let lowered = url.lowercased()
        if lowered.contains("music.youtube.com") { return .youtubeMusic }
        if lowered.contains("youtube.com") || lowered.contains("youtu.be") { return .youtube }
        if let provider = ChatProvider.from(url: url) {
            return from(provider: provider)
        }
        return nil
    }

    static func from(platform: StreamingPlatform?) -> IslandIdleDestination? {
        switch platform {
        case .youtube: return .youtube
        case .youtubeMusic: return .youtubeMusic
        default: return nil
        }
    }

    static func from(provider: ChatProvider) -> IslandIdleDestination {
        switch provider {
        case .claude: return .claude
        case .chatgpt: return .chatgpt
        case .gemini: return .gemini
        }
    }
}

enum IslandIdleDestinationRanker {
    /// Compact strip and expanded grid both need at least four shortcuts.
    static let defaultLimit = 5

    /// Recency-weighted score. Recent opens outrank old high counts.
    static func score(openCount: Int, lastOpenedAt: Date?, now: Date = Date()) -> Double {
        let count = max(0, openCount)
        guard let lastOpenedAt else { return Double(count) }
        let hours = max(0, now.timeIntervalSince(lastOpenedAt) / 3600)
        let recency = max(0, 48 - hours) / 48
        return Double(count) + recency * 8
    }

    /// Rank known destinations; zero-history entries keep catalog order as a soft default.
    static func ranked(
        stats: [IslandIdleDestination: (count: Int, lastOpenedAt: Date?)],
        limit: Int = defaultLimit,
        now: Date = Date()
    ) -> [IslandIdleDestination] {
        let scored = IslandIdleDestination.allCases.map { destination -> (IslandIdleDestination, Double, Int) in
            let entry = stats[destination]
            let value = score(
                openCount: entry?.count ?? 0,
                lastOpenedAt: entry?.lastOpenedAt,
                now: now
            )
            let order = IslandIdleDestination.allCases.firstIndex(of: destination) ?? 0
            return (destination, value, order)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.2 < rhs.2
        }
        return Array(scored.prefix(max(limit, 1)).map(\.0))
    }
}
