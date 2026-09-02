import Foundation

/// Chrome native-messaging host (stdio) and Unix-socket bridge to the running island.
enum ChromeNativeMessaging {
    static let hostName = "com.dynamicisland.chrome"
    /// Stable id from the extension's fixed public `key` in manifest.json.
    static let extensionID = "hpmejlkmljielfbmamheeocphdgdhbin"
    static let hostArg = "--chrome-native-host"

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Dynamic Island", isDirectory: true)
    }

    static var socketPath: String {
        supportDirectory.appendingPathComponent("chrome-push.sock").path
    }

    static var extensionInstallDirectory: URL {
        supportDirectory.appendingPathComponent("ChromeHelper", isDirectory: true)
    }

    static func shouldRunAsHost(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(hostArg)
    }
}

/// Separate process instance launched by Chrome. Forwards stdin JSON to the main app via Unix socket.
enum ChromeNativeMessagingHost {
    static func runAndExit() -> Never {
        let socketPath = ChromeNativeMessaging.socketPath
        FileManager.default.createDirectoryIfNeeded(at: ChromeNativeMessaging.supportDirectory)

        // Tell Chrome we are alive.
        writeNativeMessage(["type": "helloAck", "ok": true])

        while let message = readNativeMessage() {
            forwardToMainApp(message, socketPath: socketPath)
            if (message["type"] as? String) == "hello" {
                writeNativeMessage(["type": "helloAck", "ok": true, "ts": Int(Date().timeIntervalSince1970 * 1000)])
            }
        }
        exit(0)
    }

    private static func forwardToMainApp(_ message: [String: Any], socketPath: String) {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message) else {
            return
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    dest.update(from: src.baseAddress!, count: pathBytes.count)
                }
            }
        }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return }

        var length = UInt32(data.count).littleEndian
        let lengthData = Data(bytes: &length, count: 4)
        _ = lengthData.withUnsafeBytes { write(fd, $0.baseAddress, 4) }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    }

    private static func readNativeMessage() -> [String: Any]? {
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        let readLen = lengthBytes.withUnsafeMutableBytes { ptr in
            fread(ptr.baseAddress, 1, 4, stdin)
        }
        guard readLen == 4 else { return nil }
        let length = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard length > 0, length < 10_000_000 else { return nil }
        var payload = [UInt8](repeating: 0, count: Int(length))
        let readBody = payload.withUnsafeMutableBytes { ptr in
            fread(ptr.baseAddress, 1, Int(length), stdin)
        }
        guard readBody == Int(length) else { return nil }
        let data = Data(payload)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeNativeMessage(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return
        }
        var length = UInt32(data.count).littleEndian
        let lengthData = Data(bytes: &length, count: 4)
        _ = lengthData.withUnsafeBytes { fwrite($0.baseAddress, 1, 4, stdout) }
        _ = data.withUnsafeBytes { fwrite($0.baseAddress, 1, data.count, stdout) }
        fflush(stdout)
    }
}

private extension FileManager {
    func createDirectoryIfNeeded(at url: URL) {
        try? createDirectory(at: url, withIntermediateDirectories: true)
    }
}
