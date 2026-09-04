import Foundation

/// Picks which YouTube / YouTube Music tab should receive play/pause/seek.
/// Never fall through to "first tab in Chrome" — that resumes a different video.
enum YouTubeTabPicker {
    enum Bias {
        /// Pause the tab that is actually playing the Now Playing title.
        case pause
        /// Resume the tab we paused / that still shows that title.
        case play
        /// Next / previous / seek: stay on the same session.
        case sameSession
    }

    struct Tab: Equatable {
        var tabID: Int
        var url: String
        var playerTitle: String
        var playerArtist: String
        var paused: Bool
    }

    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased()
        let junk = [
            " - youtube music",
            " - youtube",
            " | youtube",
            "(official video)",
            "(official audio)",
            "(official visualiser)",
            "(lyric video)",
            "(lyrics)",
            "official video",
            "official audio"
        ]
        for token in junk {
            s = s.replacingOccurrences(of: token, with: " ")
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func titlesMatch(_ a: String, _ b: String) -> Bool {
        let x = normalize(a)
        let y = normalize(b)
        guard x.count >= 3, y.count >= 3 else { return false }
        if x.contains(y) || y.contains(x) { return true }

        let wx = x.split(separator: " ").map(String.init).filter { $0.count > 1 }
        let wy = y.split(separator: " ").map(String.init).filter { $0.count > 1 }
        guard !wx.isEmpty, !wy.isEmpty else { return false }
        let hits = wx.filter { word in
            wy.contains { other in wordsClose(word, other) }
        }.count
        let need = min(2, wx.count, wy.count)
        return hits >= need
    }

    /// Same track, not a leftover YouTube watch tab. Fuzzy `titlesMatch` treats
    /// short words ("too"/"good") as hits and bound Music to the wrong poster.
    static func titlesMatchSameTrack(_ a: String, _ b: String) -> Bool {
        let x = normalize(a)
        let y = normalize(b)
        guard x.count >= 3, y.count >= 3 else { return false }
        if x == y { return true }
        let shorter = x.count < y.count ? x : y
        let longer = x.count < y.count ? y : x
        if shorter.count >= 12, longer.contains(shorter) { return true }
        let wx = Set(significantWords(x))
        let wy = Set(significantWords(y))
        let exact = wx.intersection(wy)
        if exact.contains(where: { $0.count >= 6 }) { return true }
        return exact.filter { $0.count >= 4 }.count >= 2
    }

    private static func significantWords(_ s: String) -> [String] {
        s.split(separator: " ").map(String.init).filter { word in
            word.count >= 4 && word.rangeOfCharacter(from: .letters) != nil
        }
    }

    /// True when this browser tab's *title* is the Now Playing item.
    static func tabMatchesNowPlaying(
        tabTitle: String,
        nowPlayingTitle: String,
        nowPlayingArtist: String,
        tabURL: String = "",
        nowPlayingHint: StreamingPlatform? = nil
    ) -> Bool {
        _ = nowPlayingArtist
        if !StreamingPlatform.sourceURLCompatible(tabURL, withTitleHint: nowPlayingHint) {
            return false
        }
        return titlesMatchSameTrack(tabTitle, nowPlayingTitle)
    }

    private static func wordsClose(_ a: String, _ b: String) -> Bool {
        if a == b || a.contains(b) || b.contains(a) { return true }
        guard min(a.count, b.count) >= 3 else { return false }
        return levenshtein(a, b) <= 2
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let ac = Array(a)
        let bc = Array(b)
        if ac.isEmpty { return bc.count }
        if bc.isEmpty { return ac.count }
        var prev = Array(0...bc.count)
        var cur = Array(repeating: 0, count: bc.count + 1)
        for i in 1...ac.count {
            cur[0] = i
            for j in 1...bc.count {
                let cost = ac[i - 1] == bc[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[bc.count]
    }

    static func urlsMatch(_ a: String, _ b: String) -> Bool {
        if let leftID = youtubeVideoID(from: a), let rightID = youtubeVideoID(from: b) {
            return leftID.caseInsensitiveCompare(rightID) == .orderedSame
        }
        func core(_ url: String) -> String {
            var s = url.lowercased()
            if let q = s.firstIndex(of: "?") {
                s = String(s[..<q])
            }
            return s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let x = core(a)
        let y = core(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || x.contains(y) || y.contains(x)
    }

    /// Watch, Shorts, youtu.be, and embed URLs for the same clip.
    static func youtubeVideoID(from rawURL: String) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let components = URLComponents(string: trimmed) else {
            return nil
        }
        let host = (components.host ?? "").lowercased()
        let isYouTube = host == "youtu.be"
            || host.hasSuffix(".youtu.be")
            || host.contains("youtube")
        guard isYouTube else { return nil }

        if let queryID = components.queryItems?
            .first(where: { $0.name.lowercased() == "v" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           isPlausibleYouTubeID(queryID) {
            return queryID
        }

        let parts = components.path.split(separator: "/").map(String.init)
        if host == "youtu.be" || host.hasSuffix(".youtu.be"),
           let first = parts.first,
           isPlausibleYouTubeID(first) {
            return first
        }

        guard parts.count >= 2 else { return nil }
        let kind = parts[0].lowercased()
        let markerKinds = ["shorts", "embed", "live", "v", "watch"]
        if markerKinds.contains(kind), isPlausibleYouTubeID(parts[1]) {
            return parts[1]
        }
        return nil
    }

    private static func isPlausibleYouTubeID(_ value: String) -> Bool {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...20).contains(id.count) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func score(
        _ tab: Tab,
        nowPlayingTitle: String,
        nowPlayingArtist: String,
        preferredURL: String,
        bias: Bias
    ) -> Int {
        var value = 0
        let titleHit = titlesMatch(tab.playerTitle, nowPlayingTitle)
            || titlesMatch(tab.url, nowPlayingTitle)
        let artistHit = titlesMatch(tab.playerArtist, nowPlayingArtist)
            || titlesMatch(tab.playerTitle, nowPlayingArtist)
        if titleHit { value += 100 }
        if artistHit { value += 15 }
        if !preferredURL.isEmpty, urlsMatch(tab.url, preferredURL) { value += 80 }

        switch bias {
        case .pause:
            if !tab.paused { value += 40 }
            if tab.paused { value -= 25 }
        case .play:
            if tab.paused { value += 40 }
            if !tab.paused { value -= 15 }
        case .sameSession:
            if !tab.paused { value += 10 }
        }

        if tab.url.contains("music.youtube.com") { value += 2 }
        return value
    }

    static func pick(
        from tabs: [Tab],
        nowPlayingTitle: String,
        nowPlayingArtist: String,
        preferredURL: String,
        bias: Bias
    ) -> Tab? {
        guard !tabs.isEmpty else { return nil }
        let ranked = tabs.map { tab in
            (
                tab: tab,
                score: score(
                    tab,
                    nowPlayingTitle: nowPlayingTitle,
                    nowPlayingArtist: nowPlayingArtist,
                    preferredURL: preferredURL,
                    bias: bias
                )
            )
        }
        .sorted { $0.score > $1.score }

        guard let best = ranked.first else { return nil }

        let titleMatched = ranked.contains {
            $0.score >= 100 || titlesMatch($0.tab.playerTitle, nowPlayingTitle)
        }
        // Playing a random paused tab is what starts a different song.
        if bias == .play, !titleMatched, preferredURL.isEmpty, best.score < 80 {
            return nil
        }
        if best.score < 10 { return nil }
        return best.tab
    }
}
