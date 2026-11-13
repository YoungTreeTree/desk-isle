import AppKit
import CryptoKit
import ImageIO
import SwiftUI

// No live widget views, timers, GIF players, account data, or full-size prepared pictures.
struct LayoutThumbnail: View {
    let profile: SavedLayout
    let store: LayoutLibraryStore
    let skinURL: URL?
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.045)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "rectangle.3.group").foregroundStyle(.tertiary)
            }
        }
        .task(id: profile.scene) {
            let scene = profile.scene
            let result = await Task.detached(priority: .utility) {
                LayoutThumbnailRenderer.render(scene, store: store, skinURL: skinURL)
            }.value
            guard !Task.isCancelled else { return }
            image = result
        }
        .accessibilityHidden(true)
    }
}

private enum LayoutThumbnailRenderer {
    static func render(_ scene: LayoutScene, store: LayoutLibraryStore, skinURL: URL?) -> CGImage? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let bytes = try? encoder.encode(scene) else { return nil }
        let key = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let cache = store.root.appendingPathComponent("Thumbnails", isDirectory: true)
        let url = cache.appendingPathComponent("\(key).png")
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
        let width = 640, height = 360
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.11, green: 0.13, blue: 0.17, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(Double(width) / Double(scene.layout.width), Double(height) / Double(scene.layout.height))
        let offsetX = (Double(width) - Double(scene.layout.width) * scale) / 2
        let offsetY = (Double(height) - Double(scene.layout.height) * scale) / 2
        context.translateBy(x: offsetX, y: offsetY)
        context.scaleBy(x: scale, y: scale)
        let bounds = CGRect(x: 0, y: 0, width: scene.layout.width, height: scene.layout.height)
        if let wallpaper = try? store.wallpaper(scene.wallpaperID).frame(for: scene.layout.direction)?.image {
            context.draw(wallpaper, in: bounds)
        }
        for component in scene.layout.components {
            let rect = CGRect(x: component.x, y: scene.layout.height - component.y - component.height,
                              width: component.width, height: component.height)
            var image: CGImage?
            if component.isPicture, let id = scene.pictureIDs[component.id], let file = try? store.picture(id) {
                image = thumbnail(file.data)
            } else if component.isPet, let skinURL, let bytes = try? Data(contentsOf: skinURL) {
                image = thumbnail(bytes)
            }
            if let image {
                let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                context.draw(image, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                              width: size.width, height: size.height))
            } else {
                let shape = CGPath(roundedRect: rect.insetBy(dx: 5, dy: 5), cornerWidth: 16, cornerHeight: 16, transform: nil)
                context.addPath(shape)
                context.setFillColor(CGColor(red: 0.14, green: 0.18, blue: 0.25, alpha: 0.76))
                context.fillPath()
                // Static content lines express placement without capturing personal metrics.
                context.setFillColor(CGColor(gray: 0.95, alpha: 0.65))
                for index in 0..<3 {
                    let line = CGRect(x: rect.minX + 20, y: rect.maxY - 28 - CGFloat(index * 20),
                                      width: max(8, rect.width * (index == 0 ? 0.45 : 0.7)), height: 6)
                    if rect.contains(line) { context.fill(line) }
                }
            }
        }
        guard let result = context.makeImage() else { return nil }
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let output = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, result, nil)
            if CGImageDestinationFinalize(destination) { try? (output as Data).write(to: url, options: .atomic) }
        }
        // Bound the derived disk cache; these files can always be regenerated.
        let entries = (try? FileManager.default.contentsOfDirectory(at: cache,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        if entries.count > 64 {
            let ordered = entries.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            for old in ordered.prefix(entries.count - 64) where old.pathExtension == "png" {
                try? FileManager.default.removeItem(at: old)
            }
        }
        return result
    }

    private static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
        ] as CFDictionary)
    }
}
