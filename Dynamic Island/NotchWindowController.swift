import AppKit
import CoreGraphics
import CoreVideo
import QuartzCore
import SwiftUI
import Combine

/// Hosting view that stays visually clear and only accepts hits on the
/// island itself, so the (larger) window never paints a black frame or
/// steals hover from the menu bar.
private final class ClearHostingView<Content: View>: NSHostingView<Content> {
    /// Island bounds in this view's coordinate space.
    var islandHitRect: () -> NSRect = { .zero }

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyClearBackground()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard islandHitRect().contains(point) else { return nil }
        // NSHostingView does not forward clicks into NSViewRepresentable.
        // Only the file tray uses AppKit; music chrome stays SwiftUI.
        if let shelf = shelfAppKitView(containing: point) {
            return shelf
        }
        return super.hitTest(point)
    }

    private func shelfAppKitView(containing point: NSPoint) -> NSView? {
        var tray: ShelfTrayView?
        func walk(_ view: NSView) -> NSView? {
            if let thumb = view as? ShelfThumbView, !thumb.bounds.isEmpty {
                let rect = convert(thumb.bounds, from: thumb)
                if rect.contains(point) { return thumb }
            }
            if let found = view as? ShelfTrayView {
                tray = found
            }
            for child in view.subviews {
                if let hit = walk(child) { return hit }
            }
            return nil
        }
        if let thumb = walk(self) { return thumb }
        if let tray {
            let rect = convert(tray.bounds, from: tray)
            if rect.contains(point) { return tray }
        }
        return nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        discardCursorRects()
        let rect = islandHitRect()
        guard !rect.isNull, !rect.isEmpty else { return }
        addCursorRect(rect, cursor: .arrow)
    }

    /// SwiftUI `Text` registers an I-beam. Keep the arrow over the island for
    /// every Now Playing client, not only YouTube.
    override func cursorUpdate(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if islandHitRect().contains(local) {
            NSCursor.arrow.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    private func applyClearBackground() {
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

/// Space-swipe lift is applied here so SwiftUI cannot reset the hosting view's layer.
private final class SpaceLiftHostView: NSView {
    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
    }
}

/// Temporary vertical travel for Space / fullscreen transitions.
/// Resting geometry is unchanged; only `offsetY` is added to the window origin.
enum IslandSpaceTransitionMotion {
    /// Fast fall from above, then crawl into rest.
    static let enterFastPhaseDuration: TimeInterval = 0.098
    /// Last phase of the drop-in: crawl into the rest notch.
    static let enterSlowPhaseDuration: TimeInterval = 0.500
    /// Time for the committed drop-in from above.
    static var enterDuration: TimeInterval {
        enterFastPhaseDuration + enterSlowPhaseDuration
    }
    /// Fraction of `enterDuration` that is the fast fall from above.
    static var enterFastSplit: CGFloat {
        let duration = max(enterDuration, 0.001)
        return CGFloat(enterFastPhaseDuration / duration)
    }
    /// Apply this much of the drop-in immediately so the first on-screen frame
    /// is already peeking, instead of waiting a timer interval at fully hidden.
    static let enterFirstSample: TimeInterval = 1.0 / 120.0

    /// Distance for the visible island to clear the top of the screen.
    static func hiddenOffset(islandHeight: CGFloat) -> CGFloat {
        max(islandHeight, 1)
    }

    static func displayedFrame(resting: NSRect, offsetY: CGFloat) -> NSRect {
        resting.offsetBy(dx: 0, dy: offsetY)
    }

    /// One window, one surface: pin X and lift Y on the frame. A layer
    /// translation on top of a resting frame draws a second island during
    /// Space swipes.
    static func presentedFrame(resting: NSRect, originX: CGFloat, offsetY: CGFloat) -> NSRect {
        var frame = resting
        frame.origin.x = originX
        return displayedFrame(resting: frame, offsetY: offsetY)
    }

    static func layerTranslationY(offsetY: CGFloat, viewIsFlipped: Bool) -> CGFloat {
        viewIsFlipped ? -offsetY : offsetY
    }

    /// Quadratic ease-out for the Space-swipe hide (fast tuck, slow finish).
    static func easeOut(_ t: CGFloat) -> CGFloat {
        let u = 1 - t
        return 1 - u * u
    }

    /// Drop-in: fast fall from above, then a longer quartic crawl into rest.
    /// Smooth across the join; no bounce.
    static func enterEase(_ t: CGFloat) -> CGFloat {
        let x = min(max(t, 0), 1)
        let split = enterFastSplit
        let splitProgress: CGFloat = 1 - pow(0.55, 3)
        let startSpeed: CGFloat = 3 * 1.3
        let endPhaseSpeed: CGFloat = 3 * (1 - splitProgress) / (1 - split)
        let progress: CGFloat
        if x <= split {
            let u = x / split
            let m0 = startSpeed * split
            let m1 = endPhaseSpeed * split
            progress = hermite(u, y0: 0, y1: splitProgress, m0: m0, m1: m1)
        } else {
            let u = (x - split) / (1 - split)
            progress = splitProgress + (1 - splitProgress) * quarticEaseOut(u)
        }
        return min(max(progress, 0), 1)
    }

    static func cubicEaseOut(_ t: CGFloat) -> CGFloat {
        let u = 1 - min(max(t, 0), 1)
        return 1 - u * u * u
    }

    /// Heavier than cubic on the last stretch so rest eases in more slowly.
    static func quarticEaseOut(_ t: CGFloat) -> CGFloat {
        let u = 1 - min(max(t, 0), 1)
        return 1 - u * u * u * u
    }

    static func hermite(
        _ u: CGFloat,
        y0: CGFloat,
        y1: CGFloat,
        m0: CGFloat,
        m1: CGFloat
    ) -> CGFloat {
        let x = min(max(u, 0), 1)
        let x2 = x * x
        let x3 = x2 * x
        return (2 * x3 - 3 * x2 + 1) * y0
            + (x3 - 2 * x2 + x) * m0
            + (-2 * x3 + 3 * x2) * y1
            + (x3 - x2) * m1
    }
}

/// Menu-bar overlays need to accept controls without behaving like a normal
/// document window. A borderless NSWindow cannot become key, so SwiftUI
/// buttons inside it can hover but may reject clicks.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Rest: current Space only. Joining: briefly `canJoinAllSpaces` so
    /// `orderFront` can land on the Space that just became active.
    enum SpaceAffiliation {
        case currentSpaceOnly
        case joiningActiveSpace
    }

    var spaceAffiliation: SpaceAffiliation = .currentSpaceOnly

    /// AppKit otherwise clamps overlays to `visibleFrame` (below the menu bar)
    /// and re-clamps when the active app / fullscreen state changes.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        applyDesktopIslandSpaceBehavior()
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        applyDesktopIslandSpaceBehavior()
    }

    func applyDesktopIslandSpaceBehavior() {
        switch spaceAffiliation {
        case .currentSpaceOnly:
            collectionBehavior = IslandSurfacePolicy.desktopIslandCollectionBehavior
            collectionBehavior.subtract(IslandSurfacePolicy.spaceSwipeSnapshotBehaviors)
        case .joiningActiveSpace:
            collectionBehavior = IslandSurfacePolicy.spaceArrivalCollectionBehavior
        }
        isMovable = false
        animationBehavior = .none
        hidesOnDeactivate = false
    }
}

final class NotchWindowController: NSWindowController {
    private static let restingWindowLevel = NSWindow.Level.statusBar
    /// High enough to sit above the screenshot toolbar, without using the
    /// assistive-tech shield level that can lock out desktop input.
    private static let liveActivityWindowLevel = NSWindow.Level.popUpMenu
    let viewModel = NotchViewModel()
    private var hostingView: ClearHostingView<AnyView>?
    private var spaceLiftHost: SpaceLiftHostView?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var pointerPollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// Last notched display, so fullscreen (which can zero `safeAreaInsets`)
    /// does not retarget `NSScreen.main` / another monitor.
    private var anchoredDisplayID: CGDirectDisplayID?
    private var lastNotchGeometry: (width: CGFloat, height: CGFloat, hasNotch: Bool)?
    private var spaceObservers: [NSObjectProtocol] = []
    private var compositorDriftTimer: Timer?
    private var spaceDisplayLink: CVDisplayLink?
    private var swipeSession = IslandSpaceSwipeSession()
    private var spaceRestingFrame: NSRect = .zero
    private var spaceAnimTimer: Timer?
    private var arrivalWorkItem: DispatchWorkItem?
    private var islandHasAppeared = false
    private var lastComposedVisualX: CGFloat?
    private var lastComposedAppKitX: CGFloat?
    private var parkedAboveAt: TimeInterval?
    private var spaceTickRunning = false
    private var lastSpaceTickAt: TimeInterval = 0
    private var lastEnterFinishedAt: TimeInterval = 0
    /// After a Space change the window is still on the old Space. Stay
    /// invisible until drop-in briefly joins all Spaces, then pins here.
    private var awaitingSpaceReattach = false
    private var pinWaitGeneration = 0
    /// Ignore a one-frame “outside” glitch so the island cannot collapse
    /// under the pointer while a control is still hovered.
    private var outsideClickThroughStreak = 0
    /// Previous sample so a fast swipe that tunnels through the island still expands.
    private var lastPointerScreenPoint: NSPoint?
    private var isScrubbingFromClick = false

    convenience init() {
        let window = NotchWindowController.makeWindow()
        self.init(window: window)
        embedContent()
        observeScreenChanges()
        observeOverlayNotifications()
        startClickThroughTracking()
        observeExpansionChanges()
        observeSpaceTransitions()
    }

    deinit {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        pointerPollTimer?.invalidate()
        compositorDriftTimer?.invalidate()
        if let spaceDisplayLink {
            CVDisplayLinkStop(spaceDisplayLink)
        }
        spaceAnimTimer?.invalidate()
        arrivalWorkItem?.cancel()
        for observer in spaceObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private static func makeWindow() -> NSWindow {
        let window = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Isolation: do not change these for lock screen / loginwindow.
        // Shielding tags and isFloatingPanel = false hid Claude banners.
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = restingWindowLevel
        window.sharingType = .readWrite
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.isRestorable = false
        window.animationBehavior = .none
        window.applyDesktopIslandSpaceBehavior()
        // Start click-through so Chrome tabs / menu bar stay usable under the
        // large transparent frame. Tracking turns this off only over the island.
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = true
        return window
    }

    private func embedContent() {
        guard let window = window else { return }
        let root = AnyView(NotchView().environmentObject(viewModel))
        let hosting = ClearHostingView(rootView: root)
        hosting.islandHitRect = { [weak self, weak hosting] in
            guard let self, let hosting else { return .zero }
            return self.islandRect(in: hosting)
        }
        let liftHost = SpaceLiftHostView(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        liftHost.addSubview(hosting)
        hosting.frame = liftHost.bounds
        window.contentView = liftHost
        spaceLiftHost = liftHost
        hostingView = hosting
        positionWindow()
        updateClickThrough(withScreenPoint: NSEvent.mouseLocation)
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(positionWindow),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // AppKit can move a panel to the key window’s screen. Snap it back
        // to the anchored display; this is not app-activation tracking.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(positionWindow),
            name: NSWindow.didChangeScreenNotification,
            object: window
        )
        // Reposition on wake — display topology may have changed and
        // didChangeScreenParameters is not guaranteed on every wake path.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.positionWindow()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.positionWindow()
            }
        }
    }

    private func observeSpaceTransitions() {
        let spaceChanged = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleActiveSpaceDidChange()
        }
        spaceObservers.append(spaceChanged)

        compositorDriftTimer?.invalidate()
        compositorDriftTimer = nil
        startSpaceDisplayLink()
    }

    private func startSpaceDisplayLink() {
        if let spaceDisplayLink {
            CVDisplayLinkStop(spaceDisplayLink)
        }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
              let link else { return }
        spaceDisplayLink = link
        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, user in
            guard let user else { return kCVReturnSuccess }
            let controller = Unmanaged<NotchWindowController>.fromOpaque(user).takeUnretainedValue()
            if Thread.isMainThread {
                controller.handleSpaceSwipeTick()
            } else {
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue as CFString) {
                    controller.handleSpaceSwipeTick()
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            return kCVReturnSuccess
        }, context)
        CVDisplayLinkStart(link)
    }

    private func handleActiveSpaceDidChange() {
        beginArrival()
    }

    /// Hide on the old Space until the swipe morph is done. A Space change
    /// during drop-in must restart this — ignoring it leaves the island on
    /// the previous desktop until another swipe.
    private func beginArrival() {
        guard islandHasAppeared, !LockScreenMonitor.shared.isLocked else { return }
        guard IslandSurfacePolicy.shouldHandleSpaceSwipe(
            usesTightLiveActivityWindow: usesTightLiveActivityWindow
        ) else { return }
        pinWaitGeneration += 1
        spaceAnimTimer?.invalidate()
        spaceAnimTimer = nil
        arrivalWorkItem?.cancel()
        if swipeSession.phase == .entering {
            swipeSession.reset()
        }
        lastEnterFinishedAt = 0
        parkedAboveAt = CACurrentMediaTime()
        awaitingSpaceReattach = true
        swipeSession.spaceDidChange(islandHeight: viewModel.islandShapeHeight)
        applySpaceLiftTransform()
        if let window, let panel = window as? IslandPanel {
            panel.spaceAffiliation = .currentSpaceOnly
            panel.applyDesktopIslandSpaceBehavior()
            window.alphaValue = 0
        }
        logSpaceSwipe("beginArrival_noOrderFront")
        scheduleArrival()
    }

    private func scheduleArrival() {
        arrivalWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.beginSpaceEnterIfSettled()
        }
        arrivalWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + IslandSpaceTransitionMotion.arrivalSettle,
            execute: work
        )
    }

    private func beginSpaceEnterIfSettled() {
        guard islandHasAppeared, !LockScreenMonitor.shared.isLocked else { return }
        if awaitingSpaceReattach {
            beginSpaceEnter()
            return
        }
        switch swipeSession.phase {
        case .hidden:
            beginSpaceEnter()
        case .tracking:
            scheduleArrival()
        case .idle, .entering:
            break
        }
    }

    private func restoreRestingWindowFrame() {
        guard let window, spaceRestingFrame.width > 0 else { return }
        if window.frame != spaceRestingFrame {
            window.setFrame(spaceRestingFrame, display: false, animate: false)
        }
    }

    private func composedOriginX() -> CGFloat? {
        guard let window else { return nil }
        let options: CGWindowListOption = [.optionIncludingWindow, .excludeDesktopElements]
        let info = CGWindowListCopyWindowInfo(options, CGWindowID(window.windowNumber)) as? [[String: Any]]
        return IslandSpaceTransitionMotion.composedBounds(fromWindowInfo: info ?? [])?.origin.x
    }

    /// Let WindowServer own horizontal Space motion; only lift vertically.
    /// Counter-moving X creates alternating snapshot/live positions on slow
    /// swipes, while a resting AppKit X keeps both compositor copies aligned.
    private func handleSpaceSwipeTick() {
        guard !spaceTickRunning else { return }
        let now = CACurrentMediaTime()
        if now - lastSpaceTickAt < 0.008 { return }
        spaceTickRunning = true
        defer { spaceTickRunning = false }
        guard islandHasAppeared, !LockScreenMonitor.shared.isLocked else { return }
        guard IslandSurfacePolicy.shouldHandleSpaceSwipe(
            usesTightLiveActivityWindow: usesTightLiveActivityWindow
        ) else { return }
        guard let window, spaceRestingFrame.width > 0 else { return }
        // The timer-driven arrival owns the panel until it reaches rest.
        // WindowServer still emits the tail of a slow Space morph here; do not
        // let those samples cancel and relaunch the drop-in.
        if swipeSession.phase == .entering { return }
        lastSpaceTickAt = now

        // Do not follow compositor noise while stranded on the previous Space.
        if awaitingSpaceReattach {
            presentSpaceWindow(originX: spaceRestingFrame.origin.x)
            return
        }

        let visualX = composedOriginX() ?? window.frame.origin.x
        let appKitX = window.frame.origin.x
        let previousVisualX = lastComposedVisualX
        let deltaX = IslandSpaceTransitionMotion.stableCompositorDeltaX(
            visualX: visualX,
            appKitX: appKitX,
            lastVisualX: previousVisualX,
            lastAppKitX: lastComposedAppKitX,
            lastDeltaX: swipeSession.lastDeltaX
        )
        lastComposedVisualX = visualX
        lastComposedAppKitX = appKitX

        let restX = spaceRestingFrame.origin.x
        let screenWidth = window.screen?.frame.width
            ?? NSScreen.screens.first?.frame.width
            ?? spaceRestingFrame.width

        let compositorSnapped = previousVisualX.map { abs(visualX - $0) > 400 } ?? false

        if swipeSession.phase == .hidden,
           let parkedAboveAt,
           CACurrentMediaTime() - parkedAboveAt > IslandSpaceTransitionMotion.parkTimeout {
            self.parkedAboveAt = nil
            scheduleArrival()
            return
        }

        let action = swipeSession.tick(
            compositorDeltaX: compositorSnapped ? 0 : deltaX,
            screenWidth: screenWidth,
            islandHeight: viewModel.islandShapeHeight,
            smoothing: IslandSpaceTransitionMotion.liftSmoothing,
            compositorSnapped: compositorSnapped
        )

        switch action {
        case .rest:
            presentSpaceWindow(originX: restX)
        case .ignore:
            if swipeSession.phase == .hidden || swipeSession.phase == .entering {
                presentSpaceWindow(originX: restX)
            }
        case .follow:
            parkedAboveAt = nil
            arrivalWorkItem?.cancel()
            spaceAnimTimer?.invalidate()
            spaceAnimTimer = nil
            presentSpaceWindow(originX: restX)
        case .cancel:
            parkedAboveAt = nil
            presentSpaceWindow(originX: restX)
            scheduleArrival()
        case .park:
            parkedAboveAt = nil
            presentSpaceWindow(originX: restX)
            scheduleArrival()
        }
    }

    private func beginSpaceEnter() {
        guard !LockScreenMonitor.shared.isLocked else { return }
        switch swipeSession.phase {
        case .idle, .entering:
            return
        case .tracking, .hidden:
            break
        }
        applySpaceLiftTransform()
        reattachToActiveSpaceThenDropIn()
    }

    /// Accessory apps cannot use `moveToActiveSpace`. Briefly join every Space
    /// (user cannot see it: parked + alpha 0), wait until the window is on the
    /// active Space, then pin and drop in.
    private func reattachToActiveSpaceThenDropIn() {
        guard let window, let panel = window as? IslandPanel else { return }
        pinWaitGeneration += 1
        let generation = pinWaitGeneration
        window.alphaValue = 0
        applySpaceLiftTransform()
        panel.spaceAffiliation = .joiningActiveSpace
        panel.applyDesktopIslandSpaceBehavior()
        window.orderFrontRegardless()
        applySpaceLiftTransform()
        logSpaceSwipe("reattach_joined")
        waitUntilOnActiveSpaceThenPin(
            generation: generation,
            startedAt: CACurrentMediaTime()
        )
    }

    private func waitUntilOnActiveSpaceThenPin(generation: Int, startedAt: TimeInterval) {
        guard generation == pinWaitGeneration else { return }
        guard islandHasAppeared, !LockScreenMonitor.shared.isLocked else { return }
        guard let window, let panel = window as? IslandPanel else { return }
        panel.spaceAffiliation = .joiningActiveSpace
        panel.applyDesktopIslandSpaceBehavior()
        window.orderFrontRegardless()
        applySpaceLiftTransform()
        let ready = window.isOnActiveSpace
        let timedOut = CACurrentMediaTime() - startedAt >= IslandSpaceTransitionMotion.onActiveSpaceWait
        if ready || timedOut {
            logSpaceSwipe(ready ? "reattach_onActive" : "reattach_onActive_timeout")
            pinToCurrentSpaceAndDropIn(keepJoinedUntilVisible: !ready)
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + IslandSpaceTransitionMotion.onActiveSpacePoll
        ) { [weak self] in
            self?.waitUntilOnActiveSpaceThenPin(generation: generation, startedAt: startedAt)
        }
    }

    private func pinToCurrentSpaceAndDropIn(keepJoinedUntilVisible: Bool) {
        guard let window, let panel = window as? IslandPanel else { return }
        if keepJoinedUntilVisible {
            panel.spaceAffiliation = .joiningActiveSpace
            panel.applyDesktopIslandSpaceBehavior()
        } else {
            panel.spaceAffiliation = .currentSpaceOnly
            panel.applyDesktopIslandSpaceBehavior()
        }
        applySpaceLiftTransform()
        logSpaceSwipe("reattach_pinned")
        awaitingSpaceReattach = false
        parkedAboveAt = nil
        window.alphaValue = 1
        startParkedDropIn(pinWhenFinished: keepJoinedUntilVisible)
    }

    private func startParkedDropIn(pinWhenFinished: Bool = false) {
        logSpaceSwipe("beginSpaceEnter_dropIn")
        swipeSession.markEntering()
        animateSpaceOffset(
            to: 0,
            duration: IslandSpaceTransitionMotion.enterDuration
        ) { [weak self] in
            guard let self else { return }
            self.swipeSession.finishEnter(now: CACurrentMediaTime())
            self.lastEnterFinishedAt = CACurrentMediaTime()
            self.parkedAboveAt = nil
            self.awaitingSpaceReattach = false
            self.window?.alphaValue = 1
            if let panel = self.window as? IslandPanel {
                panel.spaceAffiliation = .currentSpaceOnly
                panel.applyDesktopIslandSpaceBehavior()
            }
            self.restoreRestingWindowFrame()
            self.applySpaceLiftTransform()
            self.logSpaceSwipe("enterFinished")
            _ = pinWhenFinished
        }
    }

    private func resetSpaceTransition() {
        spaceAnimTimer?.invalidate()
        spaceAnimTimer = nil
        arrivalWorkItem?.cancel()
        arrivalWorkItem = nil
        parkedAboveAt = nil
        awaitingSpaceReattach = false
        lastComposedVisualX = nil
        lastComposedAppKitX = nil
        lastEnterFinishedAt = 0
        pinWaitGeneration += 1
        swipeSession.reset()
        window?.alphaValue = 1
        if let panel = window as? IslandPanel {
            panel.spaceAffiliation = .currentSpaceOnly
            panel.applyDesktopIslandSpaceBehavior()
        }
        restoreRestingWindowFrame()
        applySpaceLiftTransform()
    }

    /// Runtime proof for Space-swipe debugging (not Console-only).
    private func logSpaceSwipe(_ reason: String) {
        guard let window else { return }
        let path = "/Users/user/Desktop/AI projects/Dynamic Island/.tmp/space-swipe-runtime.log"
        let line = String(
            format: "%.3f %@ behavior=%lu alpha=%.2f phase=%@ frame=(%.1f,%.1f) restY=%.1f joinAll=%d onActive=%d awaitReattach=%d\n",
            CACurrentMediaTime(),
            reason,
            UInt(window.collectionBehavior.rawValue),
            window.alphaValue,
            String(describing: swipeSession.phase),
            window.frame.origin.x,
            window.frame.origin.y,
            spaceRestingFrame.origin.y,
            window.collectionBehavior.contains(.canJoinAllSpaces) ? 1 : 0,
            window.isOnActiveSpace ? 1 : 0,
            awaitingSpaceReattach ? 1 : 0
        )
        if let data = line.data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: data)
            } else if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

    private func animateSpaceOffset(
        to target: CGFloat,
        duration: TimeInterval,
        completion: @escaping () -> Void
    ) {
        spaceAnimTimer?.invalidate()
        let start = swipeSession.offsetY
        let clampedTarget = max(0, target)
        if abs(start - clampedTarget) < 0.5 {
            applySpaceLiftTransform()
            completion()
            return
        }
        let startTime = CACurrentMediaTime() - IslandSpaceTransitionMotion.enterFirstSample
        let apply = { [weak self] (linear: CGFloat) in
            guard let self else { return }
            let t = IslandSpaceTransitionMotion.enterEase(linear)
            self.swipeSession.setEnterOffset(start + (clampedTarget - start) * t)
            self.applySpaceLiftTransform()
        }
        apply(IslandSpaceTransitionMotion.enterFirstSample / max(duration, 0.001))
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let elapsed = CACurrentMediaTime() - startTime
            let linear = min(max(elapsed / max(duration, 0.001), 0), 1)
            apply(linear)
            if linear >= 1 {
                timer.invalidate()
                self.spaceAnimTimer = nil
                self.swipeSession.setEnterOffset(clampedTarget)
                self.applySpaceLiftTransform()
                completion()
            }
        }
        spaceAnimTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func applySpaceOffsetFrame() {
        presentSpaceWindow(originX: spaceRestingFrame.origin.x)
    }

    /// Commit frame and backing-store updates on one WindowServer flush so a
    /// slow Space morph cannot alternate between the previous and next frame.
    private func presentSpaceWindow(originX: CGFloat) {
        guard let window, spaceRestingFrame.width > 0 else { return }
        let frame = IslandSpaceTransitionMotion.presentedFrame(
            resting: spaceRestingFrame,
            originX: originX,
            offsetY: swipeSession.offsetY
        )
        if abs(window.frame.origin.x - frame.origin.x) > 0.75
            || abs(window.frame.origin.y - frame.origin.y) > 0.5
            || abs(window.frame.width - frame.width) > 0.5
            || abs(window.frame.height - frame.height) > 0.5 {
            window.disableScreenUpdatesUntilFlush()
            window.setFrame(frame, display: true, animate: false)
            window.displayIfNeeded()
        }
        clearLiftLayerTransform()
    }

    private func applySpaceLiftTransform() {
        presentSpaceWindow(originX: spaceRestingFrame.origin.x)
    }

    private func clearLiftLayerTransform() {
        guard let spaceLiftHost else { return }
        spaceLiftHost.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        spaceLiftHost.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    func test_forceSpaceLift(_ offsetY: CGFloat) {
        swipeSession.reset()
        swipeSession.markEntering()
        swipeSession.setEnterOffset(offsetY)
        applySpaceLiftTransform()
        window?.displayIfNeeded()
    }

    func test_runSpaceSwipeTick() {
        handleSpaceSwipeTick()
    }

    func test_runDropInFromAbove() {
        swipeSession.reset()
        swipeSession.spaceDidChange(islandHeight: viewModel.islandShapeHeight)
        applySpaceLiftTransform()
        beginSpaceEnter()
    }

    func test_beginArrivalFromSpaceChange() {
        swipeSession.reset()
        lastEnterFinishedAt = 0
        beginArrival()
    }

    var test_joinsAllSpaces: Bool {
        window?.collectionBehavior.contains(.canJoinAllSpaces) == true
    }

    var test_isOnActiveSpace: Bool {
        window?.isOnActiveSpace == true
    }

    var test_liftTranslationY: CGFloat {
        guard let window, spaceRestingFrame.width > 0 else { return 0 }
        return window.frame.origin.y - spaceRestingFrame.origin.y
    }

    var test_liftLayerTranslationY: CGFloat {
        spaceLiftHost?.layer?.transform.m42 ?? 0
    }

    /// Capture / recording UI: use a tight interactive window. Music / idle:
    /// keep the large click-through buffer so expand doesn't resize AppKit.
    private var usesTightLiveActivityWindow: Bool {
        viewModel.isSelectingScreenToRecord || viewModel.isScreenRecording
    }

    private var needsLiveActivityElevation: Bool {
        viewModel.isOverlayActive || usesTightLiveActivityWindow
    }

    private func observeExpansionChanges() {
        Publishers.CombineLatest4(
            viewModel.$isExpanded,
            viewModel.$transientOverlay,
            viewModel.$isScreenRecording,
            viewModel.$isSelectingScreenToRecord
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.positionWindow()
            }
            .store(in: &cancellables)

        // Idle glance width/height changes with media / ranking — keep the
        // AppKit frame in sync so live matches what screenshots capture.
        Publishers.CombineLatest3(
            viewModel.$hasMedia,
            viewModel.$persistentState,
            viewModel.$idleDestinations
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.positionWindow()
            }
            .store(in: &cancellables)

        AppSettings.shared.$idleGlanceEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.positionWindow()
            }
            .store(in: &cancellables)

        // Idle glance hangs below the notch; keep the panel ordered front so
        // the visible hang isn’t buried under menu-bar chrome.
        viewModel.$hasMedia
            .combineLatest(viewModel.$persistentState, AppSettings.shared.$idleGlanceEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasMedia, state, enabled in
                guard let self, let window = self.window else { return }
                let idle = enabled && !hasMedia && state == .idle
                if idle, !LockScreenMonitor.shared.isLocked {
                    window.orderFrontRegardless()
                    self.positionWindow()
                    window.displayIfNeeded()
                }
            }
            .store(in: &cancellables)
    }

    private func applyWindowElevation() {
        guard let window else { return }
        if needsLiveActivityElevation {
            window.level = Self.liveActivityWindowLevel
            // Mid-swipe orderFront teleports a one-Space window onto the
            // incoming plate at rest. Arrival owns orderFront after park.
            if swipeSession.phase == .idle {
                window.orderFrontRegardless()
            }
        } else {
            window.level = Self.restingWindowLevel
        }
        window.sharingType = .readWrite
        (window as? IslandPanel)?.applyDesktopIslandSpaceBehavior()
    }

    var isNotchWindowVisible: Bool { window?.isVisible == true }

    func setHiddenForLockScreen(_ hidden: Bool) {
        guard let window else {
            NSLog("[LockScreen] %@ skipped, window=nil", hidden ? "orderOut" : "orderFront")
            return
        }
        if hidden {
            resetSpaceTransition()
            window.orderOut(nil)
            NSLog("[LockScreen] orderOut called, window.isVisible=%@", window.isVisible ? "true" : "false")
            return
        }
        applyWindowElevation()
        window.orderFrontRegardless()
        positionWindow()
        NSLog("[LockScreen] orderFront called, window.isVisible=%@", window.isVisible ? "true" : "false")
    }

    private func revealForOverlay() {
        guard let window else { return }
        if LockScreenMonitor.shared.isLocked { return }
        window.orderFrontRegardless()
        positionWindow()
        window.displayIfNeeded()
    }

    private func observeOverlayNotifications() {
        NotificationCenter.default.publisher(for: .overlayActivated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.revealForOverlay()
                NSLog("[NotchWindow] overlay activated; window elevated")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .overlayCleared)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.positionWindow()
                NSLog("[NotchWindow] overlay cleared; window restored")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .islandIdleGlanceExpanded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let window = self.window else { return }
                self.positionWindow()
                window.displayIfNeeded()
            }
            .store(in: &cancellables)
    }

    // MARK: - Click-through outside the island

    /// `hitTest` returning nil is not enough — the window still eats clicks.
    /// Toggle `ignoresMouseEvents` from pointer location so apps under the
    /// transparent overlay (Chrome tab strip, menu bar) stay clickable.
    /// A global event monitor requests Accessibility on recent macOS, so
    /// polling `NSEvent.mouseLocation` is the default.
    private func startClickThroughTracking() {
        if IslandSurfacePolicy.shouldInstallGlobalPointerMonitor {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
            ) { [weak self] event in
                self?.handlePointerEvent(event)
            }
        } else {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.updateClickThrough(withScreenPoint: NSEvent.mouseLocation)
            }
            RunLoop.main.add(timer, forMode: .common)
            pointerPollTimer = timer
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            if self.handlePointerEvent(event) {
                return nil
            }
            return event
        }
    }

    @discardableResult
    private func handlePointerEvent(_ event: NSEvent) -> Bool {
        let screenPoint = NSEvent.mouseLocation
        if event.type == .leftMouseDown,
           viewModel.isScreenRecording,
           viewModel.isExpanded || viewModel.showsRecordingChatDual,
           recordingStopHitRect.contains(screenPoint) {
            viewModel.stopScreenRecording()
            updateClickThrough(withScreenPoint: screenPoint)
            return true
        }
        if event.type == .leftMouseDown {
            if handleIslandClick(at: screenPoint) {
                NSCursor.arrow.set()
                updateClickThrough(withScreenPoint: screenPoint)
                return true
            }
        }
        if isScrubbingFromClick,
           event.type == .leftMouseDragged || event.type == .leftMouseUp {
            applyScrub(at: screenPoint, ended: event.type == .leftMouseUp)
            updateClickThrough(withScreenPoint: screenPoint)
            return true
        }
        updateClickThrough(withScreenPoint: screenPoint)
        return false
    }

    /// SwiftUI buttons inside this nonactivating panel often never fire.
    /// Transport, artwork, chat, and battery clicks are handled here; the
    /// progress bar and file shelf stay in their existing views.
    @discardableResult
    private func handleIslandClick(at screenPoint: NSPoint) -> Bool {
        guard let window, let hosting = hostingView else { return false }
        let islandInView = islandRect(in: hosting)
        let inWindow = hosting.convert(islandInView, to: nil)
        let inScreen = window.convertToScreen(inWindow)
        guard inScreen.contains(screenPoint) else { return false }

        let fromTopLeft = CGPoint(
            x: screenPoint.x - inScreen.minX,
            y: inScreen.maxY - screenPoint.y
        )
        let action = IslandClickPolicy.action(
            pointFromTopLeft: fromTopLeft,
            islandSize: inScreen.size,
            notchHeight: viewModel.notchHeight,
            isExpanded: viewModel.isExpanded || viewModel.isOverlayActive,
            overlay: viewModel.transientOverlay,
            hasMedia: viewModel.hasMedia,
            persistentIsMusic: viewModel.persistentState == .musicPlaying,
            showsShelf: viewModel.showsShelfRow,
            isScreenRecording: viewModel.isScreenRecording,
            showsIdleGlance: viewModel.showsIdleGlance,
            idleDestinationCount: viewModel.idleDestinations.count,
            showsDualNowPlaying: viewModel.showsDualNowPlaying,
            dualNowPlayingSwapsTiles: viewModel.dualNowPlayingSwapsTiles
        )
        switch action {
        case .passthrough:
            return false
        case .expandRecording:
            NSLog("[NotchWindow] island click expand recording")
            viewModel.expandRecordingFromClick()
        case .revealNowPlaying:
            NSLog("[NotchWindow] island click reveal now playing")
            viewModel.openNowPlayingSource()
        case .openChat:
            NSLog("[NotchWindow] island click open chat")
            viewModel.openChatTabFromOverlay()
        case .openBatterySettings:
            NSLog("[NotchWindow] island click battery settings")
            viewModel.openBatterySettingsFromOverlay()
        case .playPause:
            NSLog("[NotchWindow] island click primary play/pause")
            viewModel.togglePlayPause()
        case .skipBack:
            NSLog("[NotchWindow] island click primary skip back")
            viewModel.skipBackward()
        case .skipForward:
            NSLog("[NotchWindow] island click primary skip forward")
            viewModel.skipForward()
        case .seek:
            isScrubbingFromClick = true
            applyScrub(at: screenPoint, ended: false)
        case .openIdleDestination(let index):
            NSLog("[NotchWindow] island click idle destination %d", index)
            viewModel.openIdleDestination(at: index)
        case .secondaryRevealNowPlaying:
            NSLog("[NotchWindow] island click reveal secondary source")
            viewModel.openSecondaryNowPlayingSource()
        case .secondaryPlayPause:
            NSLog("[NotchWindow] island click secondary play/pause")
            viewModel.toggleSecondaryPlayPause()
        case .secondarySkipBack:
            NSLog("[NotchWindow] island click secondary skip back")
            viewModel.skipSecondaryBackward()
        case .secondarySkipForward:
            NSLog("[NotchWindow] island click secondary skip forward")
            viewModel.skipSecondaryForward()
        }
        return true
    }

    private func applyScrub(at screenPoint: NSPoint, ended: Bool) {
        guard let window, let hosting = hostingView else { return }
        let islandInView = islandRect(in: hosting)
        let inWindow = hosting.convert(islandInView, to: nil)
        let inScreen = window.convertToScreen(inWindow)
        let x = screenPoint.x - inScreen.minX
        let fraction = IslandClickPolicy.seekFraction(x: x, islandWidth: inScreen.width)
        if ended {
            viewModel.endScrubbing(fraction: fraction)
            isScrubbingFromClick = false
        } else if viewModel.isScrubbing {
            viewModel.updateScrubbing(fraction: fraction)
        } else {
            viewModel.beginScrubbing(at: fraction)
        }
    }

    /// Mirrors RecordingStopControl in screen coordinates, with 4pt hit slop.
    /// Dual layouts move the control into the recording column; recording-only
    /// keeps it at the trailing edge of the expanded island.
    private var recordingStopHitRect: NSRect {
        guard let window, let hosting = hostingView else { return .zero }
        let islandInView = islandRect(in: hosting)
        let local = IslandSurfacePolicy.recordingStopRect(
            islandSize: islandInView.size,
            notchHeight: viewModel.notchHeight,
            isScreenRecording: viewModel.isScreenRecording,
            isExpanded: viewModel.isExpanded || viewModel.isOverlayActive,
            dual: viewModel.dualActivity
        )
        guard local.width > 0, local.height > 0 else { return .zero }

        let viewRect: NSRect
        if hosting.isFlipped {
            viewRect = NSRect(
                x: islandInView.minX + local.minX,
                y: islandInView.minY + local.minY,
                width: local.width,
                height: local.height
            )
        } else {
            viewRect = NSRect(
                x: islandInView.minX + local.minX,
                y: islandInView.maxY - local.minY - local.height,
                width: local.width,
                height: local.height
            )
        }
        let inWindow = hosting.convert(viewRect, to: nil)
        return window.convertToScreen(inWindow).insetBy(dx: -4, dy: -4)
    }

    private func updateClickThrough(withScreenPoint screenPoint: NSPoint) {
        guard let window = window, let hosting = hostingView else { return }

        // Recording / selecting: AppKit hover (SwiftUI onHover is unreliable
        // at the notch during capture). Hit-test the island only so the
        // YouTube-sized shadow bleed does not steal desktop / capture clicks.
        if usesTightLiveActivityWindow {
            window.level = Self.liveActivityWindowLevel
            let islandInView = islandRect(in: hosting)
            let inWindow = hosting.convert(islandInView, to: nil)
            let inScreen = window.convertToScreen(inWindow)
            let previous = lastPointerScreenPoint
            let radius = IslandSurfacePolicy.islandHoverRadius(islandSize: inScreen.size)
            let inside = IslandSurfacePolicy.pointerIsOverIsland(
                point: screenPoint,
                island: inScreen,
                previous: previous,
                radius: radius
            )
            lastPointerScreenPoint = screenPoint
            bindKeyboardTransport(pointerOverIsland: inside)
            if inside {
                if window.ignoresMouseEvents {
                    window.ignoresMouseEvents = false
                }
                if viewModel.isScreenRecording {
                    viewModel.expand()
                }
            } else {
                if !window.ignoresMouseEvents {
                    window.ignoresMouseEvents = true
                }
                viewModel.releaseHoverExpandLockIfExpired()
                requestCollapseAfterPointerExit()
            }
            return
        }

        // Exact island bounds so the arrow cursor does not appear over the
        // transparent window around the notch. A larger pad while dragging
        // still lets the compact island become a drop target.
        let pad: CGFloat = NSEvent.pressedMouseButtons != 0 ? 16 : 0
        let inScreen = hoverIslandScreenRect(in: hosting, window: window, pad: pad)
        let previous = lastPointerScreenPoint
        let radius = IslandSurfacePolicy.islandHoverRadius(islandSize: inScreen.size)
        let inside = IslandSurfacePolicy.pointerIsOverIsland(
            point: screenPoint,
            island: inScreen,
            previous: previous,
            radius: radius
        )
        lastPointerScreenPoint = screenPoint
        bindKeyboardTransport(pointerOverIsland: inside)

        if inside || viewModel.isDropTargeted || viewModel.isDraggingShelfItem {
            outsideClickThroughStreak = 0
            if window.ignoresMouseEvents {
                window.ignoresMouseEvents = false
                window.enableCursorRects()
                window.invalidateCursorRects(for: hosting)
                NSCursor.arrow.set()
            }
            if !viewModel.isOverlayActive, !viewModel.isExpanded {
                viewModel.expand()
            }
            if needsLiveActivityElevation {
                window.level = Self.liveActivityWindowLevel
                window.orderFrontRegardless()
            }
        } else {
            outsideClickThroughStreak += 1
            if outsideClickThroughStreak >= 2 {
                viewModel.releaseHoverExpandLockIfExpired()
                if !window.ignoresMouseEvents {
                    window.disableCursorRects()
                    window.ignoresMouseEvents = true
                    // SwiftUI onHover may not fire once we go click-through.
                    requestCollapseAfterPointerExit()
                } else if viewModel.isExpanded {
                    requestCollapseAfterPointerExit()
                }
            }
        }
    }

    /// Collapse immediately on pointer exit — same path for idle and media.
    private func requestCollapseAfterPointerExit() {
        guard viewModel.isExpanded, !viewModel.isOverlayActive else { return }
        viewModel.collapse()
    }

    private func bindKeyboardTransport(pointerOverIsland: Bool) {
        VolumeBrightnessMonitor.shared.updateKeyboardBinding(
            mediaKeys: viewModel.hasMedia,
            arrowKeys: IslandSurfacePolicy.shouldBindArrowKeysToIsland(
                isExpanded: viewModel.isExpanded,
                hasMedia: viewModel.hasMedia,
                pointerOverIsland: pointerOverIsland
            )
        )
    }

    // MARK: - Real notch geometry

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return CGDirectDisplayID(number?.uint32Value ?? 0)
    }

    /// Built-in notched display first. Never `NSScreen.main` — that follows
    /// the key window of the active application.
    private func anchorScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let notched = screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            anchoredDisplayID = Self.displayID(of: notched)
            return notched
        }
        if let id = anchoredDisplayID,
           let remembered = screens.first(where: { Self.displayID(of: $0) == id }) {
            return remembered
        }
        return screens.first
    }

    /// Derives the physical notch width and height from the built-in display.
    /// The notch occupies the horizontal gap between `auxiliaryTopLeftArea`
    /// and `auxiliaryTopRightArea`; its height equals `safeAreaInsets.top`.
    private static func notchGeometry(for screen: NSScreen) -> (width: CGFloat, height: CGFloat, hasNotch: Bool) {
        let safeTop = screen.safeAreaInsets.top
        guard safeTop > 0 else {
            return (width: 120, height: 28, hasNotch: false)
        }

        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let notchWidth = screen.frame.width - left.width - right.width
            return (width: max(notchWidth, 100), height: safeTop, hasNotch: true)
        }

        return (width: 180, height: safeTop, hasNotch: true)
    }

    private func resolvedNotchGeometry(for screen: NSScreen) -> (width: CGFloat, height: CGFloat, hasNotch: Bool) {
        let geo = Self.notchGeometry(for: screen)
        if geo.hasNotch {
            lastNotchGeometry = geo
            return geo
        }
        if let last = lastNotchGeometry, last.hasNotch,
           anchoredDisplayID == Self.displayID(of: screen) {
            return last
        }
        return geo
    }

    /// Top of the menu-bar / notch band in global screen coordinates.
    private static func screenTopY(for screen: NSScreen) -> CGFloat {
        if let left = screen.auxiliaryTopLeftArea {
            return left.maxY
        }
        if let right = screen.auxiliaryTopRightArea {
            return right.maxY
        }
        return screen.frame.maxY
    }

    private static func anchoredFrame(on screen: NSScreen, size: CGSize) -> NSRect {
        let screenFrame = screen.frame
        let originX = screenFrame.origin.x + (screenFrame.width - size.width) / 2
        let originY = screenTopY(for: screen) - size.height
        return NSRect(x: originX, y: originY, width: size.width, height: size.height)
    }

    // MARK: - Hit testing

    /// Visible island rectangle inside the hosting view, regardless of flip.
    private func islandRect(in hosting: NSView) -> NSRect {
        let width = viewModel.islandShapeWidth
        let height = viewModel.islandShapeHeight
        let topOffset = viewModel.islandTopOffset
        let bounds = hosting.bounds
        let x = (bounds.width - width) / 2
        let y: CGFloat = hosting.isFlipped ? topOffset : (bounds.height - height - topOffset)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Hover uses the resting notch frame. After Chrome `activate`, the space
    /// compositor can lift this window so `convertToScreen` no longer matches
    /// the pointer — that collapse/expand fight is the hover lag.
    private func hoverIslandScreenRect(in hosting: NSView, window: NSWindow, pad: CGFloat) -> NSRect {
        if spaceRestingFrame.width > 1 {
            let width = viewModel.islandShapeWidth
            let height = viewModel.islandShapeHeight
            let x = spaceRestingFrame.minX + (spaceRestingFrame.width - width) / 2 - pad
            let y = spaceRestingFrame.maxY - height - viewModel.islandTopOffset - pad
            return NSRect(x: x, y: y, width: width + pad * 2, height: height + pad * 2)
        }
        let padded = islandRect(in: hosting).insetBy(dx: -pad, dy: -pad)
        let inWindow = hosting.convert(padded, to: nil)
        return window.convertToScreen(inWindow)
    }

    // MARK: - Window positioning

    @objc private func positionWindow() {
        guard let window = window else { return }
        guard let screen = anchorScreen() else { return }

        let geo = resolvedNotchGeometry(for: screen)

        if viewModel.notchWidth != geo.width {
            viewModel.notchWidth = geo.width
        }
        if viewModel.notchHeight != geo.height {
            viewModel.notchHeight = geo.height
        }
        if viewModel.hasPhysicalNotch != geo.hasNotch {
            viewModel.hasPhysicalNotch = geo.hasNotch
        }

        if IslandSurfacePolicy.shouldHideDesktopIsland(
            lockActive: LockScreenMonitor.shared.isLocked,
            overlayActive: viewModel.isOverlayActive
        ) {
            resetSpaceTransition()
            window.orderOut(nil)
            return
        }

        let frame: NSRect

        if usesTightLiveActivityWindow {
            // Island + the same 28pt shadow bleed as expanded YouTube.
            // Click-through outside the island keeps capture UI usable.
            let size = IslandMetrics.liveActivityWindowSize(
                islandWidth: viewModel.islandShapeWidth,
                islandHeight: viewModel.islandShapeHeight
            )
            frame = Self.anchoredFrame(on: screen, size: size)
        } else {
            // Large enough for the expanded music card + shadow so expanding
            // never resizes AppKit (that hover↔resize loop crashed).
            let shadowBleed = IslandMetrics.islandShadowBleed
            let maxIslandWidth = max(
                IslandMetrics.expandedWidth(notchWidth: viewModel.notchWidth),
                IslandMetrics.dualWidthFixed,
                IslandMetrics.batteryBannerWidth,
                IslandMetrics.chatOnlyWidthFixed
            )
            let size = CGSize(
                width: maxIslandWidth + shadowBleed * 2,
                height: IslandMetrics.expandedHeight
                    + IslandMetrics.shelfSectionHeight
                    + shadowBleed
                    + 2
            )
            frame = Self.anchoredFrame(on: screen, size: size)
        }

        spaceRestingFrame = frame
        islandHasAppeared = true
        applySpaceOffsetFrame()
        (window as? IslandPanel)?.applyDesktopIslandSpaceBehavior()
        if let hostingView {
            window.invalidateCursorRects(for: hostingView)
        }
        applyWindowElevation()
        updateClickThrough(withScreenPoint: NSEvent.mouseLocation)
    }
}
