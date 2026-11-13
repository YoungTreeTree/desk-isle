import SwiftUI
import ImageIO

struct ResourceThumbnail: View {
    let entry: SavedResource
    let store: ResourceLibraryStore
    var generation = 0
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.045)
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit().padding(entry.kind == .model ? 6 : 0) }
            else { Image(systemName: entry.kind == .model ? "cube.transparent" : "photo").font(.largeTitle).foregroundStyle(.tertiary) }
        }
        .task(id: "\(entry.id)-\(generation)") {
            let result = await ResourceThumbnailLoader.shared.image(entry, store: store)
            guard !Task.isCancelled else { return }
            image = result
        }
        .accessibilityHidden(true)
    }
}

/// Serial, lazy thumbnail work bounds decoding memory. The grid never starts animation players.
actor ResourceThumbnailLoader {
    static let shared = ResourceThumbnailLoader()

    func image(_ entry: SavedResource, store: ResourceLibraryStore) -> CGImage? {
        let url = store.thumbnails.appendingPathComponent("\(entry.id.uuidString).png")
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
        let image: CGImage?
        if let id = entry.pictureID, let file = try? store.layouts.picture(id),
           let source = CGImageSourceCreateWithData(file.data as CFData, nil) {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 400,
            ] as CFDictionary)
        } else if entry.kind == .wallpaper, let id = entry.wallpaperID {
            image = try? store.layouts.wallpaper(id).portrait?.image
        } else if let id = entry.modelID, let file = try? store.layouts.model(id) {
            image = ModelResourceThumbnail.render(file)
        } else { image = nil }
        if let image {
            try? FileManager.default.createDirectory(at: store.thumbnails, withIntermediateDirectories: true)
            let data = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) { try? (data as Data).write(to: url, options: .atomic) }
            }
        }
        return image
    }
}
