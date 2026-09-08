import AppKit
import SwiftUI

/// AppKit tray only. It is a row inside the existing now-playing island —
/// it does not replace compact↔expanded music.
struct ShelfTray: NSViewRepresentable {
    var items: [ShelfItem]
    var isDropTargeted: Bool
    var onTargeted: (Bool) -> Void
    var onDrop: ([NSItemProvider]) -> Bool
    var onRemove: (UUID) -> Void
    var onDragBegan: () -> Void
    var onDragEnded: (UUID, Bool) -> Void

    func makeNSView(context: Context) -> ShelfTrayView {
        let view = ShelfTrayView()
        view.onTargeted = onTargeted
        view.onDrop = onDrop
        view.onRemove = onRemove
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
        view.update(items: items, highlighted: isDropTargeted)
        return view
    }

    func updateNSView(_ nsView: ShelfTrayView, context: Context) {
        nsView.onTargeted = onTargeted
        nsView.onDrop = onDrop
        nsView.onRemove = onRemove
        nsView.onDragBegan = onDragBegan
        nsView.onDragEnded = onDragEnded
        nsView.update(items: items, highlighted: isDropTargeted)
    }
}

final class ShelfTrayView: NSView {
    var onTargeted: ((Bool) -> Void)?
    var onDrop: (([NSItemProvider]) -> Bool)?
    var onRemove: ((UUID) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: ((UUID, Bool) -> Void)?

    private var items: [ShelfItem] = []
    private var highlighted = false
    private var thumbViews: [UUID: ShelfThumbView] = [:]

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes(Self.pasteboardTypes)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: IslandMetrics.shelfRowHeight)
    }

    func update(items: [ShelfItem], highlighted: Bool) {
        self.items = items
        self.highlighted = highlighted
        rebuildThumbsIfNeeded()
        if bounds.width > 1 {
            layout()
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let box = bounds.insetBy(dx: 8, dy: 8)
        let thumb = IslandMetrics.shelfThumbSize
        var x = box.minX + 6
        let y = box.midY - thumb / 2
        for item in items {
            guard let thumbView = thumbViews[item.id] else { continue }
            thumbView.frame = NSRect(x: x, y: y, width: thumb, height: thumb)
            x += thumb + 8
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 8, dy: 8)
        let path = NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12)
        path.lineWidth = 1
        let dash: [CGFloat] = [5, 4]
        path.setLineDash(dash, count: 2, phase: 0)
        NSColor.white.withAlphaComponent(highlighted ? 0.45 : 0.30).setStroke()
        path.stroke()

        if items.isEmpty {
            let text = "Drop to hold" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(
                at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2),
                withAttributes: attrs
            )
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingSource is ShelfThumbView {
            return []
        }
        onTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingSource is ShelfThumbView {
            return []
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingSource is ShelfThumbView ? false : true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted?(false)
        if sender.draggingSource is ShelfThumbView { return false }
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let providers = urls.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() }
        guard !providers.isEmpty else { return false }
        return onDrop?(providers) ?? false
    }

    private func rebuildThumbsIfNeeded() {
        let ids = Set(items.map(\.id))
        for (id, view) in thumbViews where !ids.contains(id) {
            view.removeFromSuperview()
            thumbViews[id] = nil
        }
        for item in items {
            if let existing = thumbViews[item.id] {
                existing.item = item
                existing.onRemove = { [weak self] in self?.onRemove?(item.id) }
                existing.needsDisplay = true
                continue
            }
            let thumb = ShelfThumbView(item: item)
            thumb.onRemove = { [weak self] in self?.onRemove?(item.id) }
            thumb.onDragBegan = { [weak self] in self?.onDragBegan?() }
            thumb.onDragEnded = { [weak self] completed in
                self?.onDragEnded?(item.id, completed)
            }
            addSubview(thumb)
            thumbViews[item.id] = thumb
        }
    }

    private static let pasteboardTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        .png,
        .tiff
    ]
}

/// Apple dismiss control for a held file: SF Symbol `xmark.circle.fill`
/// (HIG: use the system clear/dismiss glyph, not a custom X).
enum ShelfCancelBadge {
    static let symbolName = "xmark.circle.fill"
    static let size: CGFloat = 16
    static let inset: CGFloat = 1

    static func rect(in bounds: NSRect) -> NSRect {
        NSRect(
            x: bounds.maxX - size - inset,
            y: bounds.minY + inset,
            width: size,
            height: size
        )
    }

    static func hitRect(in bounds: NSRect) -> NSRect {
        rect(in: bounds).insetBy(dx: -4, dy: -4).intersection(bounds)
    }

    static func draw(in bounds: NSRect) {
        let badge = rect(in: bounds)
        let halo = badge.insetBy(dx: -1, dy: -1)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: halo).fill()
        image.draw(
            in: badge,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    static var image: NSImage {
        let symbol = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Cancel"
        ) ?? NSImage()
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            .applying(
                NSImage.SymbolConfiguration(paletteColors: [
                    NSColor(white: 0.12, alpha: 0.94),
                    .white
                ])
            )
        return symbol.withSymbolConfiguration(config) ?? symbol
    }
}

final class ShelfThumbView: NSView, NSDraggingSource {
    var item: ShelfItem
    var onRemove: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: ((Bool) -> Void)?
    private var started = false

    init(item: ShelfItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityRole(.image)
        setAccessibilityLabel(item.filename)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).addClip()
        if let image = item.thumbnail {
            image.draw(in: bounds)
        } else {
            NSColor.white.withAlphaComponent(0.12).setFill()
            bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        ShelfCancelBadge.draw(in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        started = false
        guard let window else { return }
        let local = convert(event.locationInWindow, from: nil)
        if ShelfCancelBadge.hitRect(in: bounds).contains(local) {
            trackCancelClick(from: event)
            return
        }
        onDragBegan?()
        let start = event.locationInWindow
        while true {
            guard let next = window.nextEvent(
                matching: [.leftMouseUp, .leftMouseDragged],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { break }
            if next.type == .leftMouseUp {
                if !started { onDragEnded?(false) }
                return
            }
            let delta = hypot(
                next.locationInWindow.x - start.x,
                next.locationInWindow.y - start.y
            )
            if delta >= 3 {
                beginFileDrag(with: event)
                return
            }
        }
        if !started { onDragEnded?(false) }
    }

    func beginFileDrag(with event: NSEvent) {
        guard !started else { return }
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            onDragEnded?(false)
            return
        }
        started = true
        let writer = ShelfFileURLWriter(url: item.url)
        let dragItem = NSDraggingItem(pasteboardWriter: writer)
        dragItem.setDraggingFrame(bounds, contents: draggingPreview())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    private func trackCancelClick(from event: NSEvent) {
        guard let window else { return }
        while true {
            guard let next = window.nextEvent(
                matching: [.leftMouseUp, .leftMouseDragged],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { return }
            if next.type == .leftMouseUp {
                let local = convert(next.locationInWindow, from: nil)
                if ShelfCancelBadge.hitRect(in: bounds).contains(local) {
                    onRemove?()
                }
                return
            }
        }
    }

    /// Drag preview keeps the same dismiss badge attached to the file.
    private func draggingPreview() -> NSImage {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else {
            return item.thumbnail ?? NSImage(size: NSSize(width: 1, height: 1))
        }
        return NSImage(size: size, flipped: true) { rect in
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).addClip()
            if let image = self.item.thumbnail {
                image.draw(in: rect)
            } else {
                NSColor.white.withAlphaComponent(0.12).setFill()
                rect.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            ShelfCancelBadge.draw(in: rect)
            return true
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        started = false
        let droppedOutside = operation != [] && operation != .delete
            && window?.frame.contains(screenPoint) != true
        onDragEnded?(droppedOutside)
    }
}

final class ShelfFileURLWriter: NSObject, NSPasteboardWriting {
    let url: URL

    init(url: URL) {
        self.url = url
        super.init()
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL {
            return url.absoluteURL.absoluteString
        }
        if type.rawValue == "NSFilenamesPboardType" {
            return [url.path]
        }
        return nil
    }
}
