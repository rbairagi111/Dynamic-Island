import AppKit
import Foundation

/// Browser vs native Now Playing clients. Used for artwork fallback and controls.
enum MediaClient {
    static func isBrowserBundle(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        guard !id.isEmpty else { return false }
        let browsers = [
            "com.google.chrome",
            "com.apple.safari",
            "company.thebrowser.browser",
            "com.brave.browser",
            "com.microsoft.edgemac",
            "org.mozilla.firefox"
        ]
        return browsers.contains { id == $0 || id.hasPrefix($0 + ".") || id.hasPrefix($0) }
    }

    static func longestPixelSide(of image: NSImage?) -> Int {
        let size = pixelSize(of: image)
        return max(size.width, size.height)
    }

    static func pixelSize(of image: NSImage?) -> (width: Int, height: Int) {
        guard let image else { return (0, 0) }
        let wide = image.representations.map(\.pixelsWide).max() ?? 0
        let high = image.representations.map(\.pixelsHigh).max() ?? 0
        if wide > 0, high > 0 { return (wide, high) }
        let scale = max(image.recommendedLayerContentsScale(0), 1)
        return (
            Int(image.size.width * scale),
            Int(image.size.height * scale)
        )
    }

    /// Pixel crop for island artwork. YouTube `hqdefault` is 4:3 with 16:9
    /// letterbox; strip that, then take a center square so the first frame fills.
    static func squareCropRect(pixelWidth: Int, pixelHeight: Int) -> (x: Int, y: Int, side: Int) {
        var x = 0
        var y = 0
        var width = max(pixelWidth, 0)
        var height = max(pixelHeight, 0)
        guard width > 0, height > 0 else { return (0, 0, 0) }
        let aspect = Double(width) / Double(height)
        if aspect >= 1.25 && aspect <= 1.45 {
            let contentHeight = Int((Double(width) * 9.0 / 16.0).rounded())
            if contentHeight > 0 && contentHeight < height {
                y = (height - contentHeight) / 2
                height = contentHeight
            }
        }
        let side = min(width, height)
        x += (width - side) / 2
        y += (height - side) / 2
        return (x, y, side)
    }

    static func filledSquareThumbnail(_ image: NSImage) -> NSImage {
        let px = pixelSize(of: image)
        let crop = squareCropRect(pixelWidth: px.width, pixelHeight: px.height)
        guard crop.side > 0 else { return image }
        if crop.x == 0, crop.y == 0, crop.side == px.width, crop.side == px.height {
            return image
        }
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            return image
        }
        let scaleX = CGFloat(cg.width) / CGFloat(max(px.width, 1))
        let scaleY = CGFloat(cg.height) / CGFloat(max(px.height, 1))
        let rect = CGRect(
            x: CGFloat(crop.x) * scaleX,
            y: CGFloat(crop.y) * scaleY,
            width: CGFloat(crop.side) * scaleX,
            height: CGFloat(crop.side) * scaleY
        ).integral
        guard let sliced = cg.cropping(to: rect) else { return image }
        return NSImage(cgImage: sliced, size: NSSize(width: crop.side, height: crop.side))
    }

    static func resembles(_ a: NSImage, _ b: NSImage, meanAbsDelta: Float = 0.14) -> Bool {
        guard let pa = raster(a, 16), let pb = raster(b, 16), pa.count == pb.count, !pa.isEmpty else {
            return false
        }
        var acc: Float = 0
        for i in 0..<pa.count {
            acc += abs(Float(pa[i]) - Float(pb[i])) / 255
        }
        return (acc / Float(pa.count)) < meanAbsDelta
    }

    private static func raster(_ image: NSImage, _ side: Int) -> [UInt8]? {
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: side * 4,
            bitsPerPixel: 32
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        rect.fill()
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let bytes = rep.bitmapData else { return nil }
        return Array(UnsafeBufferPointer(start: bytes, count: side * side * 4))
    }
}

enum BrowserMediaControlPolicy {
    static func usesYouTubeSpecificControls(
        bundleID: String,
        platform: StreamingPlatform?
    ) -> Bool {
        guard MediaClient.isBrowserBundle(bundleID) else { return false }
        return platform == .youtube || platform == .youtubeMusic
    }
}

/// Now Playing `isPlaying` for the waveform and transport UI.
/// The bars are simulated from this flag, not from real audio — a stale
/// "playing" snapshot is why they keep dancing after a browser video pauses.
enum PlaybackPlayingPolicy {
    /// Trust MediaRemote's boolean when it is present. `playbackRate` is only
    /// a fallback; a paused session often still reports rate 1.0.
    static func isPlaying(reported: Bool?, playbackRate: Double?) -> Bool {
        if let reported { return reported }
        return (playbackRate ?? 0) > 0.01
    }

    /// In-tab HTML5 / mediaSession state wins over a Chrome snapshot that
    /// never got the pause event (common on OTT / scrape players).
    static func resolvedPlaying(remote: Bool, htmlOverride: Bool?) -> Bool {
        htmlOverride ?? remote
    }
}

enum StreamingPlatform: String, CaseIterable, Equatable {
    case primeVideo
    case netflix
    case jioHotstar
    case disneyPlus
    case youtube
    case youtubeMusic
    case spotify
    case appleMusic
    case appleTV
    case hulu
    case max
    case crunchyroll
    case twitch
    case sonyliv
    case zee5
    case jioSaavn
    case soundcloud
    case vimeo
    case plex

    var displayName: String {
        switch self {
        case .primeVideo: return "Prime Video"
        case .netflix: return "Netflix"
        case .jioHotstar: return "JioHotstar"
        case .disneyPlus: return "Disney+"
        case .youtube: return "YouTube"
        case .youtubeMusic: return "YouTube Music"
        case .spotify: return "Spotify"
        case .appleMusic: return "Music"
        case .appleTV: return "Apple TV"
        case .hulu: return "Hulu"
        case .max: return "Max"
        case .crunchyroll: return "Crunchyroll"
        case .twitch: return "Twitch"
        case .sonyliv: return "SonyLIV"
        case .zee5: return "ZEE5"
        case .jioSaavn: return "JioSaavn"
        case .soundcloud: return "SoundCloud"
        case .vimeo: return "Vimeo"
        case .plex: return "Plex"
        }
    }

    var homepageURL: URL? {
        switch self {
        case .primeVideo: return URL(string: "https://www.primevideo.com")
        case .netflix: return URL(string: "https://www.netflix.com")
        case .jioHotstar: return URL(string: "https://www.hotstar.com")
        case .disneyPlus: return URL(string: "https://www.disneyplus.com")
        case .youtube: return URL(string: "https://www.youtube.com")
        case .youtubeMusic: return URL(string: "https://music.youtube.com")
        case .spotify: return URL(string: "https://open.spotify.com")
        case .appleMusic: return URL(string: "https://music.apple.com")
        case .appleTV: return URL(string: "https://tv.apple.com")
        case .hulu: return URL(string: "https://www.hulu.com")
        case .max: return URL(string: "https://www.max.com")
        case .crunchyroll: return URL(string: "https://www.crunchyroll.com")
        case .twitch: return URL(string: "https://www.twitch.tv")
        case .sonyliv: return URL(string: "https://www.sonyliv.com")
        case .zee5: return URL(string: "https://www.zee5.com")
        case .jioSaavn: return URL(string: "https://www.jiosaavn.com")
        case .soundcloud: return URL(string: "https://soundcloud.com")
        case .vimeo: return URL(string: "https://vimeo.com")
        case .plex: return URL(string: "https://app.plex.tv")
        }
    }

    static func resolve(
        bundleID: String = "",
        appName: String = "",
        artist: String = "",
        title: String = "",
        url: String = ""
    ) -> StreamingPlatform? {
        if let fromURL = from(url: url) { return fromURL }
        if let fromBundle = from(bundleID: bundleID) { return fromBundle }
        return from(text: [appName, artist, title].joined(separator: " "))
    }

    /// Removes browser/service chrome from the title shown in the island.
    /// The untouched MediaRemote title is still retained for tab matching.
    static func displayTitle(
        mediaTitle: String,
        pageTitle: String = "",
        metadataTitle: String = "",
        platform: StreamingPlatform?
    ) -> String {
        let media = mediaTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard platform == .primeVideo || platform == .netflix else {
            return media
        }

        // Netflix often reports only "Netflix" through MediaRemote while its
        // browser tab contains "Watch <name> | Netflix".
        for candidate in [pageTitle, media, metadataTitle] where !candidate.isEmpty {
            let cleaned = cleanProviderTitle(candidate, platform: platform)
            if isMeaningfulContentTitle(cleaned, platform: platform) {
                return cleaned
            }
        }
        return platform?.displayName ?? media
    }

    static func needsContentTitleRefresh(
        mediaTitle: String,
        pageTitle: String,
        metadataTitle: String = "",
        platform: StreamingPlatform?
    ) -> Bool {
        guard platform == .primeVideo || platform == .netflix else { return false }
        return displayTitle(
            mediaTitle: mediaTitle,
            pageTitle: pageTitle,
            metadataTitle: metadataTitle,
            platform: platform
        )
        .caseInsensitiveCompare(platform?.displayName ?? "") == .orderedSame
    }

    private static func cleanProviderTitle(
        _ raw: String,
        platform: StreamingPlatform?
    ) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let commonPatterns = [
            #"(?i)^\s*watch\s+"#,
            #"(?i)\s*[-–—|:]\s*season\s+\d+.*$"#
        ]
        let providerPatterns: [String]
        switch platform {
        case .primeVideo:
            providerPatterns = [
                #"(?i)^\s*(?:amazon\s+)?prime\s+video\s*[:|–—-]\s*"#,
                #"(?i)\s*[:|–—-]\s*(?:amazon\s+)?prime\s+video(?:\s+official\s+site)?\s*$"#
            ]
        case .netflix:
            providerPatterns = [
                #"(?i)^\s*netflix\s*[:|–—-]\s*"#,
                #"(?i)\s*[:|–—-]\s*netflix(?:\s+official\s+site)?\s*$"#
            ]
        default:
            providerPatterns = []
        }
        for pattern in providerPatterns + commonPatterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func isMeaningfulContentTitle(
        _ title: String,
        platform: StreamingPlatform?
    ) -> Bool {
        let value = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return false }
        let provider = platform?.displayName.lowercased() ?? ""
        if value == provider || value == "amazon prime video" { return false }
        let genericPhrases = [
            "watch movies",
            "watch tv shows",
            "movies, tv shows",
            "sports, and live tv",
            "official site"
        ]
        return !genericPhrases.contains { value.contains($0) }
    }

    static func from(url: String) -> StreamingPlatform? {
        let lowered = url.lowercased()
        guard let host = URL(string: lowered)?.host?.lowercased() ?? hostFallback(lowered) else {
            return from(text: lowered)
        }
        if host.contains("music.youtube") { return .youtubeMusic }
        if host.contains("youtu.be") || host.contains("youtube") { return .youtube }
        if host.contains("primevideo") { return .primeVideo }
        if host.contains("amazon.") && (
            lowered.contains("/gp/video")
                || lowered.contains("primevideo")
                || lowered.contains("/video/detail")
                || lowered.contains("amazonvideo")
        ) {
            return .primeVideo
        }
        if host.contains("netflix") { return .netflix }
        if host.contains("jiohotstar") || host.contains("hotstar") { return .jioHotstar }
        if host.contains("disneyplus") || host.contains("disney+") { return .disneyPlus }
        if host.contains("open.spotify") || host.contains("spotify") { return .spotify }
        if host.contains("music.apple") { return .appleMusic }
        if host.contains("tv.apple") { return .appleTV }
        if host.contains("hulu") { return .hulu }
        if host.contains("hbomax") || host == "max.com" || host.hasSuffix(".max.com") { return .max }
        if host.contains("crunchyroll") { return .crunchyroll }
        if host.contains("twitch") { return .twitch }
        if host.contains("sonyliv") { return .sonyliv }
        if host.contains("zee5") { return .zee5 }
        if host.contains("jiosaavn") || host.contains("saavn") { return .jioSaavn }
        if host.contains("soundcloud") { return .soundcloud }
        if host.contains("vimeo") { return .vimeo }
        if host.contains("plex") { return .plex }
        return nil
    }

    static func from(bundleID: String) -> StreamingPlatform? {
        let id = bundleID.lowercased()
        guard !id.isEmpty, !MediaClient.isBrowserBundle(id) else { return nil }
        if id.contains("primevideo") || id.contains("aiv.aivapp") || id.contains("amazon.aiv") {
            return .primeVideo
        }
        if id.contains("netflix") { return .netflix }
        if id.contains("hotstar") { return .jioHotstar }
        if id.contains("disneyplus") || id.contains("disney.disneyplus") { return .disneyPlus }
        if id.contains("spotify") { return .spotify }
        if id == "com.apple.music" || id.hasPrefix("com.apple.music.") { return .appleMusic }
        if id == "com.apple.tv" || id.hasPrefix("com.apple.tv.") { return .appleTV }
        if id.contains("hulu") { return .hulu }
        if id.contains("hbomax") || id.contains(".max") { return .max }
        if id.contains("crunchyroll") { return .crunchyroll }
        if id.contains("twitch") { return .twitch }
        if id.contains("sonyliv") { return .sonyliv }
        if id.contains("zee5") { return .zee5 }
        if id.contains("jiosaavn") || id.contains("saavn") { return .jioSaavn }
        if id.contains("soundcloud") { return .soundcloud }
        if id.contains("plex") { return .plex }
        return nil
    }

    static func from(text: String) -> StreamingPlatform? {
        let s = text.lowercased()
        guard !s.isEmpty else { return nil }
        if s.contains("youtube music") { return .youtubeMusic }
        if s.contains("prime video") || s.contains("amazon prime") { return .primeVideo }
        if s.contains("jiohotstar") || s.contains("jio hotstar") || s.contains("disney+ hotstar")
            || s.contains("disney plus hotstar") || (s.contains("hotstar") && !s.contains("disney+")) {
            return .jioHotstar
        }
        if s.contains("disney+") || s.contains("disney plus") { return .disneyPlus }
        if s.contains("netflix") { return .netflix }
        if s.contains("apple tv") || s.contains("tv+") { return .appleTV }
        if s.contains("youtube") { return .youtube }
        if s.contains("spotify") { return .spotify }
        if s.contains("apple music") { return .appleMusic }
        if s.contains("hulu") { return .hulu }
        if s.contains("hbo max") { return .max }
        if s.contains("crunchyroll") { return .crunchyroll }
        if s.contains("twitch") { return .twitch }
        if s.contains("sonyliv") || s.contains("sony liv") { return .sonyliv }
        if s.contains("zee5") { return .zee5 }
        if s.contains("jiosaavn") || s.contains("jio saavn") { return .jioSaavn }
        if s.contains("soundcloud") { return .soundcloud }
        if s.contains("vimeo") { return .vimeo }
        if s.contains("plex") { return .plex }
        return nil
    }

    private static func hostFallback(_ url: String) -> String? {
        if let range = url.range(of: "://") {
            let rest = url[range.upperBound...]
            return rest.split(separator: "/").first.map(String.init)
        }
        return nil
    }
}

enum MediaArtworkPolicy {
    /// Browser media often publishes Chrome’s Google icon or a tiny favicon
    /// instead of a poster. Replace that with the platform mark; keep real art.
    static func shouldUsePlatformLogo(
        hasArtwork: Bool,
        longestPixelSide: Int,
        resemblesBrowserIcon: Bool,
        isBrowser: Bool,
        platform: StreamingPlatform?
    ) -> Bool {
        guard let platform else { return false }
        if isBrowser {
            // YouTube already publishes the video's thumbnail through
            // MediaRemote. Preserve it unless the browser supplied no useful
            // artwork. Other resolved streaming sites use their official mark.
            if platform == .youtube || platform == .youtubeMusic {
                return !hasArtwork || resemblesBrowserIcon
            }
            return true
        }
        if !hasArtwork { return true }
        if resemblesBrowserIcon { return true }
        _ = longestPixelSide
        return false
    }

    /// Chrome's Now Playing artwork is a square app/favicon JPEG, or a tiny
    /// 16:9 preview (≈150×83). YouTube posters are wider and much larger.
    static func isLikelyVideoThumbnail(pixelWidth: Int, pixelHeight: Int) -> Bool {
        guard pixelWidth >= 240, pixelHeight >= 140 else { return false }
        let aspect = Double(pixelWidth) / Double(pixelHeight)
        return aspect >= 1.25 && aspect <= 2.4
    }

    static func isYouTubePosterToken(_ token: String) -> Bool {
        token.contains("ytimg:")
    }

    /// YouTube Music publishes square album covers (MediaRemote and the
    /// player-bar image), not 16:9 watch posters.
    static func isLikelyAlbumArtwork(pixelWidth: Int, pixelHeight: Int) -> Bool {
        guard pixelWidth >= 120, pixelHeight >= 120 else { return false }
        let aspect = Double(pixelWidth) / Double(pixelHeight)
        return aspect >= 0.8 && aspect <= 1.25
    }

    /// Show MediaRemote art immediately when it is already a poster. Hold
    /// square browser icons until YouTube's thumbnail (or tab URL) arrives.
    static func shouldShowBrowserRemoteArtwork(
        platform: StreamingPlatform?,
        resemblesBrowserIcon: Bool,
        isLikelyVideoThumbnail: Bool,
        hasRemote: Bool,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0
    ) -> Bool {
        guard hasRemote, !resemblesBrowserIcon else { return false }
        if isLikelyVideoThumbnail { return true }
        if platform == .youtubeMusic {
            return isLikelyAlbumArtwork(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }
        return false
    }
}

enum StreamingPlatformArtwork {
    /// Every mapped asset below is bundled verbatim from the platform's
    /// official website. Unsupported platforms keep MediaRemote artwork.
    static func image(for platform: StreamingPlatform) -> NSImage? {
        let assetName: String?
        switch platform {
        case .primeVideo: assetName = "PrimeVideoOfficialLogo"
        case .netflix: assetName = "NetflixOfficialLogo"
        case .jioHotstar: assetName = "JioHotstarOfficialLogo"
        case .youtube, .youtubeMusic: assetName = "YouTubeOfficialLogo"
        case .spotify: assetName = "SpotifyOfficialLogo"
        case .max: assetName = "MaxOfficialLogo"
        case .twitch: assetName = "TwitchOfficialLogo"
        case .jioSaavn: assetName = "JioSaavnOfficialLogo"
        case .soundcloud: assetName = "SoundCloudOfficialLogo"
        case .vimeo: assetName = "VimeoOfficialLogo"
        case .plex: assetName = "PlexOfficialLogo"
        case .disneyPlus, .appleMusic, .appleTV, .hulu, .crunchyroll, .sonyliv, .zee5:
            assetName = nil
        }
        guard let assetName else { return nil }
        return NSImage(named: NSImage.Name(assetName))
    }

    private static func render(_ platform: StreamingPlatform) -> NSImage {
        let size = NSSize(width: 128, height: 128)
        return NSImage(size: size, flipped: false) { rect in
            let radius: CGFloat = 28
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            switch platform {
            case .primeVideo: drawPrime(in: rect)
            case .netflix: drawNetflix(in: rect)
            case .jioHotstar: drawHotstar(in: rect)
            case .disneyPlus: drawDisney(in: rect)
            case .youtube, .youtubeMusic: drawYouTube(in: rect, music: platform == .youtubeMusic)
            case .spotify: drawSpotify(in: rect)
            case .appleMusic: drawAppleMusic(in: rect)
            case .appleTV: drawAppleTV(in: rect)
            case .hulu: drawHulu(in: rect)
            case .max: drawMax(in: rect)
            case .crunchyroll: drawCrunchyroll(in: rect)
            case .twitch: drawTwitch(in: rect)
            case .sonyliv: drawWordmark(in: rect, fill: NSColor(srgbRed: 0.05, green: 0.15, blue: 0.45, alpha: 1), text: "LIV")
            case .zee5: drawWordmark(in: rect, fill: NSColor(srgbRed: 0.55, green: 0.05, blue: 0.15, alpha: 1), text: "ZEE")
            case .jioSaavn: drawWordmark(in: rect, fill: NSColor(srgbRed: 0.1, green: 0.45, blue: 0.85, alpha: 1), text: "Saavn")
            case .soundcloud: drawWordmark(in: rect, fill: NSColor(srgbRed: 1, green: 0.46, blue: 0, alpha: 1), text: "SC")
            case .vimeo: drawWordmark(in: rect, fill: NSColor(srgbRed: 0.09, green: 0.72, blue: 0.96, alpha: 1), text: "v")
            case .plex: drawWordmark(in: rect, fill: NSColor(srgbRed: 0.91, green: 0.76, blue: 0.16, alpha: 1), text: "Plex", darkText: true)
            }
            return true
        }
    }

    private static func drawPrime(in rect: NSRect) {
        NSColor(srgbRed: 0.06, green: 0.09, blue: 0.12, alpha: 1).setFill()
        rect.fill()
        let smile = NSBezierPath()
        let y = rect.midY + 10
        smile.move(to: NSPoint(x: rect.minX + 22, y: y))
        smile.curve(
            to: NSPoint(x: rect.maxX - 22, y: y),
            controlPoint1: NSPoint(x: rect.midX - 10, y: y + 28),
            controlPoint2: NSPoint(x: rect.midX + 28, y: y + 28)
        )
        NSColor(srgbRed: 0.00, green: 0.66, blue: 0.88, alpha: 1).setStroke()
        smile.lineWidth = 8
        smile.lineCapStyle = .round
        smile.stroke()
        drawCenteredText("prime", in: rect.offsetBy(dx: 0, dy: -18), size: 28, color: .white, weight: .semibold)
    }

    private static func drawNetflix(in rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
        let red = NSColor(srgbRed: 0.90, green: 0.04, blue: 0.08, alpha: 1)
        let w: CGFloat = 22
        let left = NSRect(x: rect.midX - 28, y: rect.minY + 18, width: w, height: rect.height - 36)
        let right = NSRect(x: rect.midX + 6, y: rect.minY + 18, width: w, height: rect.height - 36)
        NSColor(white: 0.25, alpha: 1).setFill()
        left.fill()
        right.fill()
        let diag = NSBezierPath()
        diag.move(to: NSPoint(x: left.minX, y: left.maxY))
        diag.line(to: NSPoint(x: left.minX + w, y: left.maxY))
        diag.line(to: NSPoint(x: right.maxX, y: right.minY))
        diag.line(to: NSPoint(x: right.maxX - w, y: right.minY))
        diag.close()
        red.setFill()
        diag.fill()
    }

    private static func drawHotstar(in rect: NSRect) {
        NSColor(srgbRed: 0.04, green: 0.07, blue: 0.16, alpha: 1).setFill()
        rect.fill()
        let play = NSBezierPath()
        play.move(to: NSPoint(x: rect.midX - 16, y: rect.midY - 22))
        play.line(to: NSPoint(x: rect.midX - 16, y: rect.midY + 22))
        play.line(to: NSPoint(x: rect.midX + 24, y: rect.midY))
        play.close()
        NSColor(srgbRed: 1, green: 0.75, blue: 0.12, alpha: 1).setFill()
        play.fill()
    }

    private static func drawDisney(in rect: NSRect) {
        NSColor(srgbRed: 0.05, green: 0.10, blue: 0.28, alpha: 1).setFill()
        rect.fill()
        drawCenteredText("+", in: rect, size: 72, color: .white, weight: .light)
    }

    private static func drawYouTube(in rect: NSRect, music: Bool) {
        NSColor(srgbRed: 0.06, green: 0.06, blue: 0.06, alpha: 1).setFill()
        rect.fill()
        let badge = NSRect(x: rect.midX - 40, y: rect.midY - 28, width: 80, height: 56)
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 16, yRadius: 16).fill()
        let play = NSBezierPath()
        play.move(to: NSPoint(x: rect.midX - 10, y: rect.midY - 14))
        play.line(to: NSPoint(x: rect.midX - 10, y: rect.midY + 14))
        play.line(to: NSPoint(x: rect.midX + 16, y: rect.midY))
        play.close()
        NSColor.white.setFill()
        play.fill()
        if music {
            drawCenteredText("Music", in: rect.offsetBy(dx: 0, dy: -48), size: 14, color: .white, weight: .medium)
        }
    }

    private static func drawSpotify(in rect: NSRect) {
        NSColor(srgbRed: 0.11, green: 0.73, blue: 0.33, alpha: 1).setFill()
        rect.fill()
        NSColor.black.setStroke()
        for (i, inset) in [22, 34, 46].enumerated() {
            let path = NSBezierPath()
            let y = rect.midY + 14 - CGFloat(i) * 14
            path.move(to: NSPoint(x: rect.minX + CGFloat(inset), y: y))
            path.curve(
                to: NSPoint(x: rect.maxX - CGFloat(inset) + 4, y: y - 4),
                controlPoint1: NSPoint(x: rect.midX - 8, y: y + 10),
                controlPoint2: NSPoint(x: rect.midX + 16, y: y + 10)
            )
            path.lineWidth = 7
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    private static func drawAppleMusic(in rect: NSRect) {
        NSColor(srgbRed: 0.98, green: 0.22, blue: 0.35, alpha: 1).setFill()
        rect.fill()
        drawCenteredText("♪", in: rect, size: 64, color: .white, weight: .regular)
    }

    private static func drawAppleTV(in rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
        drawCenteredText("tv", in: rect, size: 42, color: .white, weight: .semibold)
    }

    private static func drawHulu(in rect: NSRect) {
        NSColor(srgbRed: 0.11, green: 0.73, blue: 0.33, alpha: 1).setFill()
        rect.fill()
        drawCenteredText("hulu", in: rect, size: 28, color: .white, weight: .bold)
    }

    private static func drawMax(in rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
        drawCenteredText("max", in: rect, size: 32, color: .white, weight: .bold)
    }

    private static func drawCrunchyroll(in rect: NSRect) {
        NSColor(srgbRed: 0.96, green: 0.49, blue: 0.04, alpha: 1).setFill()
        rect.fill()
        let inner = NSBezierPath(ovalIn: rect.insetBy(dx: 28, dy: 28))
        NSColor.white.setFill()
        inner.fill()
        NSColor(srgbRed: 0.96, green: 0.49, blue: 0.04, alpha: 1).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 48, dy: 48)).fill()
    }

    private static func drawTwitch(in rect: NSRect) {
        NSColor(srgbRed: 0.57, green: 0.27, blue: 1, alpha: 1).setFill()
        rect.fill()
        drawCenteredText("Tw", in: rect, size: 36, color: .white, weight: .bold)
    }

    private static func drawWordmark(in rect: NSRect, fill: NSColor, text: String, darkText: Bool = false) {
        fill.setFill()
        rect.fill()
        drawCenteredText(text, in: rect, size: text.count > 3 ? 22 : 36, color: darkText ? .black : .white, weight: .bold)
    }

    private static func drawCenteredText(
        _ string: String,
        in rect: NSRect,
        size: CGFloat,
        color: NSColor,
        weight: NSFont.Weight
    ) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let text = NSAttributedString(string: string, attributes: attrs)
        let textSize = text.size()
        let origin = NSPoint(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2
        )
        text.draw(at: origin)
    }
}
