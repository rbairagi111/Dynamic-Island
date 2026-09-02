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
        let inset: CGFloat = 8
        let box = bounds.insetBy(dx: inset, dy: 6)
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
        let box = bounds.insetBy(dx: 8, dy: 6)
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
        onTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted?(false)
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
                existing.needsDisplay = true
                continue
            }
            let thumb = ShelfThumbView(item: item)
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

final class ShelfThumbView: NSView, NSDraggingSource {
    var item: ShelfItem
    var onDragBegan: (() -> Void)?
    var onDragEnded: ((Bool) -> Void)?
    private var started = false

    init(item: ShelfItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let image = item.thumbnail {
            image.draw(in: bounds)
        } else {
            NSColor.white.withAlphaComponent(0.12).setFill()
            bounds.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        started = false
        guard let window else { return }
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
        dragItem.setDraggingFrame(bounds, contents: item.thumbnail)
        beginDraggingSession(with: [dragItem], event: event, source: self)
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
