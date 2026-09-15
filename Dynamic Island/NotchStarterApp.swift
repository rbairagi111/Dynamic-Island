import SwiftUI
import AppKit
import Darwin

@main
struct Dynamic_IslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Chrome launches a second process instance for native messaging.
        // Exit before any island UI / monitors start.
        if ChromeNativeMessaging.shouldRunAsHost() {
            ChromeNativeMessagingHost.runAndExit()
        }
    }

    var body: some Scene {
        // MenuBarExtra (not NSStatusItem) is required so Settings has a real
        // SwiftUI environment. Accessory + showSettingsWindow: opens nothing.
        MenuBarExtra("Dynamic Island", image: "HeaderIcon") {
            StatusMenuContent()
        }

        Settings {
            SettingsView(
                settings: AppSettings.shared,
                onRecheckAutomation: {
                    ChromeTabMonitor.shared.recheckPermissionsAndResume()
                }
            )
            .onAppear(perform: AppDelegate.revealSettingsWindow)
            .onDisappear {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Quit Dynamic Island") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}

private struct StatusMenuContent: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            AppDelegate.presentSettings(openSettings)
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Dynamic Island") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var notchWindowController: NotchWindowController?
    var lockScreenWindowController: LockScreenWindowController?
    private var instanceLockFD: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ChromeNativeMessaging.shouldRunAsHost() {
            ChromeNativeMessagingHost.runAndExit()
        }

        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            // XCTest hosts this app. The live island lock would terminate the
            // runner with exit 0 before tests connect.
            NSApp.setActivationPolicy(.regular)
            return
        }

        guard acquireSingleInstanceLock() else {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("island session")
        // Leftover F-key remaps from a previous binary survive SIGKILL / Xcode Stop.
        VolumeBrightnessMonitor.shared.restoreMediaKeyMappings()
        ChromeHelperInstaller.ensureNativeHostRegistered()
        ChromePushBridge.shared.start()
        _ = LockScreenMonitor.shared
        // Keep restore hooks. Do not paint the menu-bar wallpaper black while
        // the island lifts off the notch during Space swipes.
        MenuBarWallpaperTint.installLifecycleHooks()
        MenuBarWallpaperTint.restore()

        let notch = NotchWindowController()
        notchWindowController = notch
        notch.showWindow(nil)
        lockScreenWindowController = LockScreenWindowController(
            viewModel: notch.viewModel,
            notch: notch
        )

        if CommandLine.arguments.contains("--preview-claude") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(
                    name: .previewChatReady,
                    object: nil,
                    userInfo: ["provider": ChatProvider.claude.rawValue]
                )
            }
        }

        if CommandLine.arguments.contains("--preview-shelf") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotificationCenter.default.post(name: .previewShelfHold, object: nil)
            }
        }

        if CommandLine.arguments.contains("--replay-ftue") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NotificationCenter.default.post(name: .replayFTUEIntro, object: nil)
            }
        }
    }

    private func acquireSingleInstanceLock() -> Bool {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.rohitbairagi.Dynamic-Island.ui.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        instanceLockFD = fd
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        VolumeBrightnessMonitor.shared.restoreForTermination()
        MenuBarWallpaperTint.restore()
        guard instanceLockFD >= 0 else { return }
        flock(instanceLockFD, LOCK_UN)
        close(instanceLockFD)
        instanceLockFD = -1
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Accessory apps have no app menu, so `showSettingsWindow:` is a no-op.
    /// Flip to `.regular` long enough for the Settings scene to appear.
    static func presentSettings(_ openSettings: OpenSettingsAction) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.async {
            revealSettingsWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            revealSettingsWindow()
        }
    }

    static func revealSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: { isSettingsWindow($0) }) else { return }
        fitSettingsWindowToVisibleScreen(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Keep Settings on-screen. A fixed SwiftUI height taller than the display
    /// clips the shelf / recording sections; this clamps the window and lets
    /// the Form scroll so every section is reachable.
    private static func fitSettingsWindowToVisibleScreen(_ window: NSWindow) {
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 720)
        let chrome: CGFloat = 28
        let maxHeight = max(420, visible.height - chrome)
        let width: CGFloat = 500
        let height = min(maxHeight, 720)

        window.minSize = NSSize(width: 440, height: 360)
        window.maxSize = NSSize(width: 640, height: maxHeight)
        window.styleMask.insert(.resizable)

        var frame = window.frame
        frame.size = NSSize(width: width, height: height)
        frame.origin.x = visible.midX - width / 2
        frame.origin.y = visible.maxY - height - 12
        if frame.minY < visible.minY + 8 {
            frame.origin.y = visible.minY + 8
            frame.size.height = visible.maxY - frame.origin.y - 12
        }
        window.setFrame(frame, display: true)
    }

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        let id = window.identifier?.rawValue ?? ""
        if id.localizedCaseInsensitiveContains("settings") { return true }
        let title = window.title
        return title.localizedCaseInsensitiveContains("settings")
            || title.localizedCaseInsensitiveContains("preferences")
    }
}
