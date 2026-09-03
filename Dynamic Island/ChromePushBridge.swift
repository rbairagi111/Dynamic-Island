import Foundation
import Combine

/// Receives push events from the Chrome native-messaging host over a Unix socket.
final class ChromePushBridge {
    static let shared = ChromePushBridge()

    /// Called on the main queue when a reply finishes in a watched tab.
    var onReplyReady: ((ClaudeTabSnapshot, Bool, Bool) -> Void)?
    /// True when the extension has said hello recently.
    private(set) var isHelperConnected = false {
        didSet {
            if isHelperConnected != oldValue {
                DispatchQueue.main.async {
                    AppSettings.shared.chromeHelperConnected = self.isHelperConnected
                    if self.isHelperConnected {
                        AppSettings.shared.updateChromeHelperStatus("Helper connected — push notifications")
                    }
                }
            }
        }
    }

    private var listenSource: DispatchSourceRead?
    private var listenFD: Int32 = -1
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var clientBuffers: [Int32: Data] = [:]
    private let queue = DispatchQueue(label: "island.chrome-push", qos: .userInitiated)
    private var lastHelloAt: Date?
    private var heartbeatTimer: DispatchSourceTimer?

    private init() {}

    func start() {
        queue.async { [weak self] in
            self?.startListening()
            self?.startHeartbeatWatch()
        }
        ChromeHelperInstaller.ensureNativeHostRegistered()
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.heartbeatTimer?.cancel()
            self.heartbeatTimer = nil
            self.listenSource?.cancel()
            self.listenSource = nil
            if self.listenFD >= 0 {
                close(self.listenFD)
                self.listenFD = -1
            }
            for (fd, source) in self.clientSources {
                source.cancel()
                close(fd)
            }
            self.clientSources.removeAll()
            self.clientBuffers.removeAll()
            unlink(ChromeNativeMessaging.socketPath)
            self.isHelperConnected = false
        }
    }

    private func startHeartbeatWatch() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let last = self.lastHelloAt, Date().timeIntervalSince(last) < 45 {
                self.isHelperConnected = true
            } else if self.isHelperConnected {
                self.isHelperConnected = false
                DispatchQueue.main.async {
                    AppSettings.shared.updateChromeHelperStatus("Polling (enable Chrome helper for instant alerts)")
                }
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func startListening() {
        let path = ChromeNativeMessaging.socketPath
        unlink(path)
        try? FileManager.default.createDirectory(
            at: ChromeNativeMessaging.supportDirectory,
            withIntermediateDirectories: true
        )

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("[ChromePush] socket() failed")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    dest.update(from: src.baseAddress!, count: pathBytes.count)
                }
            }
        }

        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindOK == 0 else {
            NSLog("[ChromePush] bind failed for %@", path)
            close(fd)
            return
        }
        guard listen(fd, 8) == 0 else {
            close(fd)
            return
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        listenSource = source
        NSLog("[ChromePush] listening on %@", path)
    }

    private func acceptClient() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        clientBuffers[client] = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readClient(client)
        }
        source.setCancelHandler { [weak self] in
            close(client)
            self?.clientBuffers.removeValue(forKey: client)
            self?.clientSources.removeValue(forKey: client)
        }
        source.resume()
        clientSources[client] = source
    }

    private func readClient(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        if n <= 0 {
            clientSources[fd]?.cancel()
            return
        }
        var data = clientBuffers[fd] ?? Data()
        data.append(contentsOf: buf.prefix(n))
        while data.count >= 4 {
            let length = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            guard length > 0, length < 5_000_000 else {
                data.removeAll()
                break
            }
            if data.count < 4 + Int(length) { break }
            let payload = data.subdata(in: 4..<(4 + Int(length)))
            data.removeSubrange(0..<(4 + Int(length)))
            handlePayload(payload)
        }
        clientBuffers[fd] = data
    }

    private func handlePayload(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return
        }

        if type == "hello" {
            lastHelloAt = Date()
            isHelperConnected = true
            return
        }

        guard type == "replyReady" else { return }
        lastHelloAt = Date()
        isHelperConnected = true

        let providerRaw = (obj["provider"] as? String) ?? "claude"
        guard let provider = ChatProvider(rawValue: providerRaw) else { return }
        let preview = ((obj["preview"] as? String) ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard preview.count >= 8 else { return }

        let chromeTabId = obj["chromeTabId"] as? Int ?? -1
        let pageVisible = (obj["pageVisible"] as? Bool) ?? false
        let tabActive = (obj["tabActive"] as? Bool) ?? false
        let textLength = obj["textLength"] as? Int ?? preview.count
        let assistantCount = obj["assistantCount"] as? Int ?? 1

        let snapshot = ClaudeTabSnapshot(
            tab: ClaudeTabInfo(
                tabID: chromeTabId >= 0 ? chromeTabId : Int(Date().timeIntervalSince1970),
                windowIndex: 1,
                tabIndex: 1,
                provider: provider,
                url: (obj["url"] as? String) ?? ""
            ),
            isGenerating: false,
            preview: preview,
            foundDOM: true,
            textLength: textLength,
            assistantCount: assistantCount,
            latestUserPrompt: (obj["latestUserPrompt"] as? String) ?? "",
            latestUserFingerprint: (obj["latestUserFingerprint"] as? String) ?? "",
            replyFingerprint: (obj["replyFingerprint"] as? String) ?? "",
            replyAnchoredToLatestUser: (obj["replyAnchoredToLatestUser"] as? Bool) ?? true,
            networkCompletionToken: (obj["networkCompletionToken"] as? String) ?? "",
            // Only the extension's "looking at this tab" flag — never tabActive
            // alone, or a background Claude tab is treated as already viewed.
            pageVisible: pageVisible
        )

        DispatchQueue.main.async { [weak self] in
            self?.onReplyReady?(snapshot, pageVisible, tabActive)
        }
    }
}
