import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SQLite3
import UniformTypeIdentifiers

struct AirDropArrival: Equatable {
    var fileCount: Int
    var subtitle: String
    var senderName: String
    var thumbnail: NSImage?

    static let receiving = AirDropArrival(
        fileCount: 0,
        subtitle: "Receiving…",
        senderName: "AirDrop",
        thumbnail: nil
    )

    var isReceivingPlaceholder: Bool { fileCount == 0 && subtitle == "Receiving…" }

    static func == (lhs: AirDropArrival, rhs: AirDropArrival) -> Bool {
        lhs.fileCount == rhs.fileCount
            && lhs.subtitle == rhs.subtitle
            && lhs.senderName == rhs.senderName
            && lhs.thumbnail === rhs.thumbnail
    }
}

enum AirDropDSP {
    static let uiBundleIDs: Set<String> = [
        "com.apple.Sharing.AirDropUI",
        "com.apple.sharing.AirDropUI",
        "com.apple.AirDrop",
        "com.apple.SharingViewService",
        "com.apple.sharingd.AirDrop"
    ]

    static func isAirDropWhereFroms(_ values: [String]) -> Bool {
        values.contains { $0.localizedCaseInsensitiveContains("airdrop") }
    }

    static func isAirDropQuarantine(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains("sharingd")
    }

    static func isAirDropUIApp(bundleID: String?, localizedName: String?) -> Bool {
        if let bundleID, uiBundleIDs.contains(bundleID) { return true }
        if let localizedName, localizedName.localizedCaseInsensitiveContains("airdrop") {
            return true
        }
        return false
    }

    static func windowLooksLikeIncomingAirDrop(owner: String, title: String) -> Bool {
        let ownerL = owner.lowercased()
        let titleL = title.lowercased()
        if ownerL.contains("finder") { return false }
        if ownerL.contains("airdrop") { return true }
        if ownerL.contains("sharingview") { return true }
        if titleL.contains("airdrop") { return true }
        return false
    }

    static func isRecent(_ date: Date, now: Date = Date(), window: TimeInterval = 90) -> Bool {
        now.timeIntervalSince(date) <= window && now.timeIntervalSince(date) >= -5
    }

    static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path.lowercased()
            if seen.insert(key).inserted {
                out.append(url)
            }
        }
        return out
    }

    static func subtitle(fileCount: Int, photoCount: Int, videoCount: Int) -> String {
        if fileCount <= 0 { return "Receiving…" }
        if photoCount > 0, videoCount == 0, photoCount == fileCount {
            return photoCount == 1 ? "1 Photo" : "\(photoCount) Photos"
        }
        if videoCount > 0, photoCount == 0, videoCount == fileCount {
            return videoCount == 1 ? "1 Video" : "\(videoCount) Videos"
        }
        return fileCount == 1 ? "1 File" : "\(fileCount) Files"
    }

    static func merge(_ a: AirDropArrival, _ b: AirDropArrival) -> AirDropArrival {
        if a.isReceivingPlaceholder { return b }
        if b.isReceivingPlaceholder { return a }
        let count = max(a.fileCount, b.fileCount)
        let richer = b.fileCount >= a.fileCount ? b : a
        return AirDropArrival(
            fileCount: count,
            subtitle: richer.subtitle,
            senderName: a.senderName == "AirDrop" ? b.senderName : a.senderName,
            thumbnail: a.thumbnail ?? b.thumbnail
        )
    }

    static func isAcceptTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t == "accept" || t == "decline" || t == "allow" || t == "reject" || t == "don't accept"
    }
}

/// Incoming AirDrop: receive UI, Launch Services quarantine (`sharingd`), and Spotlight.
final class AirDropMonitor: NSObject {
    static let shared = AirDropMonitor()

    var onArrival: ((AirDropArrival) -> Void)?
    var onTransferring: ((Bool) -> Void)?

    private var query: NSMetadataQuery?
    private var seen = Set<String>()
    private var seenQuarantine = Set<String>()
    private var sessionPaths = Set<String>()
    private var sessionExtraFiles = 0
    private var sessionSender = "AirDrop"
    private var batch: [URL] = []
    private var flushWork: DispatchWorkItem?
    private var didSeed = false
    private var didSeedQuarantine = false
    private var pollTimer: Timer?
    private var lastTransferring = false

    private override init() {
        super.init()
    }

    func start() {
        if query == nil {
            startSpotlight()
        }
        if pollTimer == nil {
            poll()
            let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
                self?.poll()
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
    }

    func suppressSystemProgressUI() {
        Self.dismissSystemAirDropProgress()
    }

    func previewArrival() -> AirDropArrival {
        AirDropArrival(
            fileCount: 1,
            subtitle: "1 Photo",
            senderName: "Chi",
            thumbnail: Self.previewThumbnail()
        )
    }

    private func startSpotlight() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryIndexedLocalComputerScope]
        query.predicate = NSPredicate(
            format: "kMDItemWhereFroms CONTAINS[cd] %@",
            "AirDrop"
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryUpdated),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryUpdated),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        query.start()
        self.query = query
    }

    private func poll() {
        let uiVisible = Self.isAirDropUIRunning()
        let acceptPrompt = uiVisible && Self.isAcceptPromptVisible()
        let transferring = uiVisible && !acceptPrompt

        if transferring {
            Self.dismissSystemAirDropProgress()
        }

        if transferring != lastTransferring {
            lastTransferring = transferring
            if transferring {
                onTransferring?(true)
            } else if !acceptPrompt {
                onTransferring?(false)
                scheduleSessionReset()
            }
        }
        ingestQuarantineEvents()
    }

    private static func isAirDropUIRunning() -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: { app in
            AirDropDSP.isAirDropUIApp(
                bundleID: app.bundleIdentifier,
                localizedName: app.localizedName
            )
        }) {
            return true
        }
        guard canReadWindowTitles(),
              let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return info.contains { window in
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let title = window[kCGWindowName as String] as? String ?? ""
            return AirDropDSP.windowLooksLikeIncomingAirDrop(owner: owner, title: title)
        }
    }

    /// Reading window titles triggers Screen Recording TCC. Never request it.
    private static func canReadWindowTitles() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private static func isAcceptPromptVisible() -> Bool {
        // Without Accessibility we cannot tell Accept from progress — leave the sheet alone.
        guard AXIsProcessTrusted() else { return true }
        return airDropUIPIDs().contains { processContainsAcceptPrompt(pid: $0) }
    }

    private static func airDropUIPIDs() -> Set<pid_t> {
        var pids = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications {
            if AirDropDSP.isAirDropUIApp(bundleID: app.bundleIdentifier, localizedName: app.localizedName) {
                pids.insert(app.processIdentifier)
            }
        }
        guard canReadWindowTitles(),
              let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return pids }
        for window in info {
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let title = window[kCGWindowName as String] as? String ?? ""
            guard AirDropDSP.windowLooksLikeIncomingAirDrop(owner: owner, title: title) else { continue }
            if let pid = window[kCGWindowOwnerPID as String] as? pid_t {
                pids.insert(pid)
            }
        }
        return pids
    }

    private static func processContainsAcceptPrompt(pid: pid_t) -> Bool {
        axTreeContainsAccept(AXUIElementCreateApplication(pid), depth: 0)
    }

    private static func axTreeContainsAccept(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth < 8 else { return false }
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String,
           AirDropDSP.isAcceptTitle(title) {
            return true
        }
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String, role == (kAXButtonRole as String) {
            var descRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef) == .success,
               let desc = descRef as? String,
               AirDropDSP.isAcceptTitle(desc) {
                return true
            }
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return false }
        return children.contains { axTreeContainsAccept($0, depth: depth + 1) }
    }

    private static func dismissSystemAirDropProgress() {
        for app in NSWorkspace.shared.runningApplications {
            guard AirDropDSP.isAirDropUIApp(
                bundleID: app.bundleIdentifier,
                localizedName: app.localizedName
            ) else { continue }
            app.hide()
        }
        for pid in airDropUIPIDs() {
            AXUIElementSetAttributeValue(
                AXUIElementCreateApplication(pid),
                kAXHiddenAttribute as CFString,
                kCFBooleanTrue
            )
        }
    }

    private func ingestQuarantineEvents() {
        let events = Self.readRecentSharingdEvents()
        if !didSeedQuarantine {
            seenQuarantine = Set(events.map(\.id))
            didSeedQuarantine = true
            return
        }
        var urls: [URL] = []
        var extras = 0
        var sender = "AirDrop"
        var found = false
        for event in events {
            if seenQuarantine.contains(event.id) { continue }
            seenQuarantine.insert(event.id)
            guard AirDropDSP.isRecent(event.timestamp) else { continue }
            found = true
            if let url = event.fileURL {
                urls.append(url)
            } else {
                extras += 1
            }
            if event.sender != "AirDrop" {
                sender = event.sender
            }
        }
        guard found else { return }
        if sender != "AirDrop" {
            sessionSender = sender
        }
        enqueue(urls: urls, extraFiles: extras)
    }

    @objc private func queryUpdated(_ note: Notification) {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        if !didSeed {
            for i in 0..<query.resultCount {
                if let item = query.result(at: i) as? NSMetadataItem,
                   let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                    seen.insert(path)
                }
            }
            didSeed = true
            return
        }

        let now = Date()
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            if seen.contains(path) { continue }
            let created = (item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date)
                ?? (item.value(forAttribute: NSMetadataItemContentCreationDateKey) as? Date)
            if let created, now.timeIntervalSince(created) > 90 { continue }
            seen.insert(path)
            batch.append(URL(fileURLWithPath: path))
        }
        if !batch.isEmpty {
            enqueue(urls: batch, extraFiles: 0)
            batch.removeAll()
        }
    }

    private func enqueue(urls: [URL], extraFiles: Int) {
        guard !urls.isEmpty || extraFiles > 0 else { return }
        for url in AirDropDSP.uniqueURLs(urls) {
            sessionPaths.insert(url.standardizedFileURL.path)
        }
        sessionExtraFiles += extraFiles
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushBatch()
        }
        flushWork = work
        // Wait for sibling files in the same drop before announcing a count.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: work)
    }

    private func flushBatch() {
        let urls = sessionPaths.map { URL(fileURLWithPath: $0) }
        let count = max(urls.count, sessionPaths.count + sessionExtraFiles)
        guard count > 0 else { return }
        emitArrival(from: urls, extraCount: sessionExtraFiles, senderHint: sessionSender)
        if seen.count > 400 {
            seen.removeAll()
        }
    }

    private func scheduleSessionReset() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.lastTransferring else { return }
            self.sessionPaths.removeAll()
            self.sessionExtraFiles = 0
            self.sessionSender = "AirDrop"
        }
    }

    private func emitArrival(from urls: [URL], extraCount: Int, senderHint: String?) {
        var arrival = Self.arrival(from: urls, extraCount: extraCount)
        if let senderHint, arrival.senderName == "AirDrop" {
            arrival.senderName = senderHint
        }
        onArrival?(arrival)
    }

    private struct QuarantineEvent {
        var id: String
        var timestamp: Date
        var sender: String
        var fileURL: URL?
    }

    private static func readRecentSharingdEvents() -> [QuarantineEvent] {
        let dbURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT LSQuarantineEventIdentifier, LSQuarantineTimeStamp,
               LSQuarantineSenderName, LSQuarantineDataURLString
        FROM LSQuarantineEvent
        WHERE LSQuarantineAgentName = 'sharingd'
        ORDER BY LSQuarantineTimeStamp DESC
        LIMIT 40
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var events: [QuarantineEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = QuarantineSQL.string(stmt, 0) ?? UUID().uuidString
            let stamp = sqlite3_column_double(stmt, 1)
            let sender = QuarantineSQL.string(stmt, 2)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = QuarantineSQL.string(stmt, 3)
            let url: URL? = {
                guard let path, !path.isEmpty else { return nil }
                if path.hasPrefix("file:") { return URL(string: path) }
                return URL(fileURLWithPath: path)
            }()
            events.append(QuarantineEvent(
                id: id,
                timestamp: Date(timeIntervalSinceReferenceDate: stamp),
                sender: (sender?.isEmpty == false) ? sender! : "AirDrop",
                fileURL: url
            ))
        }
        return events
    }

    private static func arrival(from urls: [URL], extraCount: Int = 0) -> AirDropArrival {
        let unique = AirDropDSP.uniqueURLs(urls)
        let photos = unique.filter { Self.isImage($0) }.count
        let videos = unique.filter { Self.isVideo($0) }.count
        let fileCount = unique.count + extraCount
        return AirDropArrival(
            fileCount: fileCount,
            subtitle: AirDropDSP.subtitle(
                fileCount: fileCount,
                photoCount: photos,
                videoCount: videos
            ),
            senderName: unique.first.map(Self.senderName(for:)) ?? "AirDrop",
            thumbnail: (unique.first { Self.isImage($0) } ?? unique.first).map(Self.thumbnail(for:))
        )
    }

    private static func senderName(for url: URL) -> String {
        let item = NSMetadataItem(url: url)
        if let froms = item?.value(forAttribute: "kMDItemWhereFroms") as? [String] {
            if let name = froms.first(where: {
                !$0.localizedCaseInsensitiveContains("airdrop")
                    && !$0.contains("://")
                    && $0.count < 48
                    && !$0.isEmpty
            }) {
                return name
            }
        }
        if let authors = item?.value(forAttribute: NSMetadataItemAuthorsKey) as? [String],
           let author = authors.first, !author.isEmpty {
            return author
        }
        return "AirDrop"
    }

    private static func thumbnail(for url: URL) -> NSImage {
        if isImage(url), let image = NSImage(contentsOf: url) {
            return image
        }
        if let type = UTType(filenameExtension: url.pathExtension) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    private static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }

    private static func previewThumbnail() -> NSImage {
        let size = NSSize(width: 120, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.45, green: 0.62, blue: 0.78, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor(calibratedRed: 0.55, green: 0.48, blue: 0.38, alpha: 1).setFill()
        let mountain = NSBezierPath()
        mountain.move(to: NSPoint(x: 0, y: 28))
        mountain.line(to: NSPoint(x: 38, y: 78))
        mountain.line(to: NSPoint(x: 72, y: 42))
        mountain.line(to: NSPoint(x: 98, y: 88))
        mountain.line(to: NSPoint(x: 120, y: 36))
        mountain.line(to: NSPoint(x: 120, y: 0))
        mountain.line(to: NSPoint(x: 0, y: 0))
        mountain.close()
        mountain.fill()
        NSColor(calibratedWhite: 0.95, alpha: 0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: 78, y: 86, width: 22, height: 22)).fill()
        image.unlockFocus()
        return image
    }
}

private enum QuarantineSQL {
    static func string(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }
}
