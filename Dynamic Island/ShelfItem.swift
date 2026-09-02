import AppKit
import Foundation
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case image
        case video
        case file

        var badgeSymbol: String {
            switch self {
            case .image: return "photo"
            case .video: return "video.fill"
            case .file: return "doc.fill"
            }
        }
    }

    let id: UUID
    let url: URL
    let filename: String
    let kind: Kind
    let addedAt: Date
    let thumbnail: NSImage?
    var isPreview: Bool = false

    var standardizedPath: String {
        url.standardizedFileURL.path
    }

    static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool {
        lhs.id == rhs.id
    }
}

enum ShelfLogic {
    static let maxItems = 8

    static func inserting(_ item: ShelfItem, into items: [ShelfItem]) -> [ShelfItem] {
        if items.contains(where: { $0.standardizedPath == item.standardizedPath }) {
            return items
        }
        var next = items
        next.append(item)
        if next.count > maxItems {
            next.removeFirst(next.count - maxItems)
        }
        return next
    }

    static func removing(id: UUID, from items: [ShelfItem]) -> [ShelfItem] {
        items.filter { $0.id != id }
    }

    static func expiredIDs(
        in items: [ShelfItem],
        now: Date,
        interval: TimeInterval?
    ) -> [UUID] {
        guard let interval, interval > 0 else { return [] }
        return items.compactMap { item in
            now.timeIntervalSince(item.addedAt) >= interval ? item.id : nil
        }
    }

    static func kind(for url: URL) -> ShelfItem.Kind {
        let ext = url.pathExtension
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .audiovisualContent) {
                return .video
            }
            if type.conforms(to: .image) {
                return .image
            }
        }
        return .file
    }

    static func makeItem(
        url: URL,
        addedAt: Date = Date(),
        thumbnail: NSImage? = nil,
        kind: ShelfItem.Kind? = nil,
        filename: String? = nil,
        isPreview: Bool = false
    ) -> ShelfItem {
        let resolved = url.standardizedFileURL
        let resolvedKind = kind ?? Self.kind(for: resolved)
        return ShelfItem(
            id: UUID(),
            url: resolved,
            filename: filename ?? resolved.lastPathComponent,
            kind: resolvedKind,
            addedAt: addedAt,
            thumbnail: thumbnail ?? thumbnailImage(for: resolved, kind: resolvedKind),
            isPreview: isPreview
        )
    }

    static func thumbnailImage(for url: URL, kind: ShelfItem.Kind) -> NSImage {
        if kind == .image, let image = NSImage(contentsOf: url) {
            return scaled(image, longestSide: 128)
        }
        if kind == .video, let poster = videoPoster(url) {
            return scaled(poster, longestSide: 128)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func scaled(_ image: NSImage, longestSide: CGFloat) -> NSImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > 0 else { return image }
        let scale = min(1, longestSide / longest)
        let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let out = NSImage(size: target)
        out.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        out.unlockFocus()
        return out
    }

    private static func videoPoster(_ url: URL) -> NSImage? {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}

enum ShelfDropIngest {
    static var inboxDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Dynamic Island/ShelfInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let acceptedTypeIdentifiers: [String] = [
        UTType.fileURL.identifier,
        UTType.image.identifier,
        UTType.png.identifier,
        UTType.tiff.identifier,
        UTType.jpeg.identifier,
        UTType.movie.identifier,
        UTType.video.identifier,
        UTType.mpeg4Movie.identifier,
        UTType.quickTimeMovie.identifier,
        UTType.audiovisualContent.identifier
    ]

    static let acceptedTypes: [UTType] = [
        .fileURL, .image, .movie, .video, .mpeg4Movie, .quickTimeMovie, .png, .tiff, .jpeg, .audiovisualContent
    ]

    static func load(_ provider: NSItemProvider, completion: @escaping (ShelfItem?) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = fileURL(from: item), FileManager.default.fileExists(atPath: url.path) {
                    completion(ShelfLogic.makeItem(url: url))
                    return
                }
                loadFileRepresentation(provider, completion: completion)
            }
            return
        }
        loadFileRepresentation(provider, completion: completion)
    }

    private static func loadFileRepresentation(_ provider: NSItemProvider, completion: @escaping (ShelfItem?) -> Void) {
        let identifiers = [
            UTType.mpeg4Movie.identifier,
            UTType.quickTimeMovie.identifier,
            UTType.movie.identifier,
            UTType.video.identifier,
            UTType.png.identifier,
            UTType.tiff.identifier,
            UTType.jpeg.identifier,
            UTType.image.identifier
        ]
        if let identifier = identifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                guard let url else {
                    loadImageData(provider, completion: completion)
                    return
                }
                completion(copyIntoInbox(from: url, preferredExtension: URL(fileURLWithPath: identifier).pathExtension))
            }
            return
        }
        loadImageData(provider, completion: completion)
    }

    private static func loadImageData(_ provider: NSItemProvider, completion: @escaping (ShelfItem?) -> Void) {
        let identifiers = [UTType.png.identifier, UTType.tiff.identifier, UTType.jpeg.identifier, UTType.image.identifier]
        guard let identifier = identifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
            completion(nil)
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
            guard let data else {
                completion(nil)
                return
            }
            let ext: String
            if identifier == UTType.png.identifier {
                ext = "png"
            } else if identifier == UTType.jpeg.identifier {
                ext = "jpg"
            } else if identifier == UTType.tiff.identifier {
                ext = "tiff"
            } else {
                ext = "png"
            }
            completion(writeInboxFile(data: data, pathExtension: ext))
        }
    }

    static func copyIntoInbox(from url: URL, preferredExtension: String) -> ShelfItem? {
        let ext = url.pathExtension.isEmpty ? preferredExtension : url.pathExtension
        let dest = uniqueInboxURL(filename: url.deletingPathExtension().lastPathComponent, pathExtension: ext)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return ShelfLogic.makeItem(url: dest)
        } catch {
            return ShelfLogic.makeItem(url: url)
        }
    }

    static func writeInboxFile(data: Data, pathExtension: String) -> ShelfItem? {
        let dest = uniqueInboxURL(filename: "Screenshot", pathExtension: pathExtension)
        do {
            try data.write(to: dest)
            return ShelfLogic.makeItem(url: dest)
        } catch {
            return nil
        }
    }

    static func uniqueInboxURL(filename: String, pathExtension: String) -> URL {
        let safe = filename.isEmpty ? "Drop" : filename
        let ext = pathExtension.isEmpty ? "dat" : pathExtension
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        return inboxDirectory.appendingPathComponent("\(safe)-\(stamp).\(ext)")
    }

    static func fileURL(from item: Any?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            if let url = URL(string: string), url.isFileURL { return url }
            return URL(fileURLWithPath: string)
        }
        return nil
    }
}

/// Sample files for Settings → Preview held files / drop-here.
enum ShelfPreview {
    static func sampleItems() -> [ShelfItem] {
        [
            swatch(
                filename: "Screenshot.png",
                kind: .image,
                top: NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.95, alpha: 1),
                bottom: NSColor(calibratedRed: 0.15, green: 0.28, blue: 0.55, alpha: 1)
            ),
            swatch(
                filename: "Screen Recording.mp4",
                kind: .video,
                top: NSColor(calibratedRed: 0.95, green: 0.32, blue: 0.28, alpha: 1),
                bottom: NSColor(calibratedRed: 0.45, green: 0.08, blue: 0.12, alpha: 1)
            ),
            swatch(
                filename: "Notes.pdf",
                kind: .file,
                top: NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.58, alpha: 1),
                bottom: NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.25, alpha: 1)
            )
        ].compactMap { $0 }
    }

    private static func swatch(
        filename: String,
        kind: ShelfItem.Kind,
        top: NSColor,
        bottom: NSColor
    ) -> ShelfItem? {
        let image = gradientImage(top: top, bottom: bottom, label: filename)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else { return nil }
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        let url = ShelfDropIngest.uniqueInboxURL(filename: "Preview-\(stem)", pathExtension: ext.isEmpty ? "png" : ext)
        do {
            try data.write(to: url)
        } catch {
            return nil
        }
        return ShelfLogic.makeItem(
            url: url,
            thumbnail: image,
            kind: kind,
            filename: filename,
            isPreview: true
        )
    }

    private static func gradientImage(top: NSColor, bottom: NSColor, label: String) -> NSImage {
        let size = NSSize(width: 128, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(starting: top, ending: bottom)?.draw(in: NSRect(origin: .zero, size: size), angle: 270)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = label as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .paragraphStyle: paragraph
        ]
        let textRect = NSRect(x: 6, y: 8, width: 116, height: 28)
        text.draw(in: textRect, withAttributes: attrs)
        image.unlockFocus()
        return image
    }
}
