import Foundation
import CryptoKit
import ImageIO

enum ResourceKind: String, Codable, Sendable { case image, model, wallpaper }
enum ResourceRole: String, Codable, Sendable { case picture, wallpaper, model }

struct ResourceFile: Codable, Equatable, Sendable {
    var id: UUID
    var role: ResourceRole
    var quality: Model3DQuality?
}

struct SavedResource: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var kind: ResourceKind
    var fingerprint: String
    var importedAt = Date()
    var lastUsedAt: Date?
    var favorite = false
    var files: [ResourceFile]
    var preferredModelID: UUID?
    var width: Int?
    var height: Int?
    var animated = false

    var assetIDs: Set<UUID> { Set(files.map(\.id)) }
    var pictureID: UUID? { files.first { $0.role == .picture }?.id }
    var wallpaperID: UUID? { files.first { $0.role == .wallpaper }?.id }
    var modelID: UUID? { preferredModelID ?? files.first { $0.role == .model }?.id }
    var recentDate: Date { lastUsedAt ?? importedAt }
    var detail: String {
        if kind == .model { return "GLB · \(Set(files.compactMap(\.quality)).count) 个质量版本" }
        if kind == .wallpaper { return "旧壁纸 · 仅有适配版" }
        let size = width.flatMap { w in height.map { " · \(w) × \($0)" } } ?? ""
        return (animated ? "动态图片" : "图片") + size
    }
}

struct ResourceCatalog: Codable, Sendable {
    var version = 1
    var entries: [SavedResource] = []
    // Remember explicit deletions even if a failed file removal leaves bytes behind.
    var deletedAssetIDs: Set<UUID> = []
    var assetIDs: Set<UUID> { Set(entries.flatMap { $0.assetIDs }) }
}

/// Owns the user's collection independently of layout references. Every mutation is serialized,
/// including callers on background preparation tasks. Asset payloads remain immutable.
struct ResourceLibraryStore: Sendable {
    let layouts: LayoutLibraryStore
    private static let lock = NSRecursiveLock()
    var manifest: URL { layouts.root.appendingPathComponent("Resources.json") }
    var backup: URL { layouts.root.appendingPathComponent("Resources.backup.json") }
    var thumbnails: URL { layouts.root.appendingPathComponent("ResourceThumbnails", isDirectory: true) }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try body()
    }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func decode(_ data: Data) throws -> ResourceCatalog {
        let catalog = try JSONDecoder().decode(ResourceCatalog.self, from: data)
        guard catalog.version == 1 else { throw LayoutLibraryError.message("资源库版本不受支持，请更新桌屿。") }
        let ids = catalog.entries.map(\.id)
        let assets = catalog.entries.flatMap { $0.files.map(\.id) }
        guard Set(ids).count == ids.count, Set(assets).count == assets.count,
              catalog.deletedAssetIDs.isDisjoint(with: assets),
              catalog.entries.allSatisfy({ entry in
                  !entry.files.isEmpty && (entry.preferredModelID == nil || entry.files.contains { $0.id == entry.preferredModelID && $0.role == .model })
              }) else {
            throw LayoutLibraryError.message("资源库索引损坏，原文件已保留。")
        }
        return catalog
    }

    private func read() throws -> ResourceCatalog {
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            if FileManager.default.fileExists(atPath: backup.path) { return try decode(Data(contentsOf: backup)) }
            return ResourceCatalog()
        }
        do { return try decode(Data(contentsOf: manifest)) }
        catch {
            if let data = try? Data(contentsOf: manifest),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = json["version"] as? Int, version != 1 { throw error }
            if let data = try? Data(contentsOf: backup), let recovered = try? decode(data) { return recovered }
            throw error
        }
    }

    private func save(_ catalog: ResourceCatalog) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(catalog)
        _ = try decode(data)
        try FileManager.default.createDirectory(at: layouts.root, withIntermediateDirectories: true)
        if let old = try? Data(contentsOf: manifest), (try? decode(old)) != nil {
            try old.write(to: backup, options: .atomic)
        }
        try data.write(to: manifest, options: .atomic)
    }

    /// Reconcile also runs after legacy layout migration. Unknown/corrupt files are never
    /// overwritten; old IDs are retained so saved layouts and recovery snapshots keep working.
    func load() throws -> ResourceCatalog {
        try locked {
            var catalog = try read()
            let known = catalog.assetIDs.union(catalog.deletedAssetIDs)
            let directory = layouts.root.appendingPathComponent("Assets", isDirectory: true)
            let urls: [URL]
            if FileManager.default.fileExists(atPath: directory.path) {
                urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            } else { urls = [] }
            var changed = false
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard url.pathExtension == "plist", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      !known.contains(id), let data = try? Data(contentsOf: url) else { continue }
                let decoder = PropertyListDecoder()
                var entry: SavedResource
                if let file = try? decoder.decode(PictureFile.self, from: data), let image = try? imageEntry(file) {
                    entry = image
                    entry.files = [ResourceFile(id: id, role: .picture)]
                } else if let file = try? decoder.decode(Model3DFile.self, from: data) {
                    entry = SavedResource(name: file.name, kind: .model, fingerprint: Self.fingerprint(file.source),
                                          files: [ResourceFile(id: id, role: .model, quality: file.quality ?? .original)])
                } else if let saved = try? decoder.decode(SavedWallpaper.self, from: data), (try? saved.makeWallpaper()) != nil {
                    entry = SavedResource(name: saved.name, kind: .wallpaper,
                                          fingerprint: Self.fingerprint(saved.portrait + saved.landscape + (saved.nativeLandscape ?? Data())),
                                          files: [ResourceFile(id: id, role: .wallpaper)])
                } else { continue }
                entry.importedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if let index = catalog.entries.firstIndex(where: { $0.kind == entry.kind && $0.fingerprint == entry.fingerprint }) {
                    catalog.entries[index].files.append(contentsOf: entry.files)
                    catalog.entries[index].importedAt = min(catalog.entries[index].importedAt, entry.importedAt)
                } else { catalog.entries.append(entry) }
                changed = true
            }
            if changed { try save(catalog) }
            return catalog
        }
    }

    private func imageEntry(_ file: PictureFile) throws -> SavedResource {
        guard let image = CGImageSourceCreateWithData(file.data as CFData, nil), CGImageSourceGetCount(image) > 0,
              let info = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int,
              let height = info[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { throw PictureError.unreadable }
        return SavedResource(name: file.name, kind: .image, fingerprint: Self.fingerprint(file.data), files: [],
                             width: width, height: height, animated: CGImageSourceGetCount(image) > 1)
    }

    func storePicture(_ file: PictureFile) throws -> UUID {
        try locked {
            var catalog = try load()
            var entry = try imageEntry(file)
            if let existing = catalog.entries.first(where: { $0.kind == .image && $0.fingerprint == entry.fingerprint }),
               let id = existing.pictureID, let saved = try? layouts.picture(id), saved.data == file.data { return id }
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let id = try layouts.storeAsset(encoder.encode(file))
            if let index = catalog.entries.firstIndex(where: { $0.kind == .image && $0.fingerprint == entry.fingerprint }) {
                catalog.entries[index].files.insert(ResourceFile(id: id, role: .picture), at: 0)
            } else {
                entry.files = [ResourceFile(id: id, role: .picture)]
                catalog.entries.append(entry)
            }
            try save(catalog)
            return id
        }
    }

    func storeModel(_ file: Model3DFile) throws -> UUID {
        try locked {
            var catalog = try load()
            let hash = Self.fingerprint(file.source)
            let index = catalog.entries.firstIndex { $0.kind == .model && $0.fingerprint == hash }
            if let index {
                for variant in catalog.entries[index].files where variant.quality == (file.quality ?? .original) {
                    if let old = try? layouts.model(variant.id), old.pack == file.pack { return variant.id }
                }
            }
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let id = try layouts.storeAsset(encoder.encode(file))
            let variant = ResourceFile(id: id, role: .model, quality: file.quality ?? .original)
            if let index { catalog.entries[index].files.append(variant) }
            else { catalog.entries.append(SavedResource(name: file.name, kind: .model, fingerprint: hash, files: [variant])) }
            try save(catalog)
            return id
        }
    }

    func importWallpaper(from url: URL) throws -> (UUID, ScreenWallpaper) {
        try locked {
            let pictureID = try storePicture(PictureFile(from: url))
            let catalog = try load()
            guard let entry = catalog.entries.first(where: { $0.assetIDs.contains(pictureID) }) else { throw WallpaperError.storageFailed }
            return try wallpaper(for: entry.id)
        }
    }

    func wallpaper(for resourceID: UUID) throws -> (UUID, ScreenWallpaper) {
        try locked {
            var catalog = try load()
            guard let index = catalog.entries.firstIndex(where: { $0.id == resourceID }) else { throw WallpaperError.unreadable }
            let entry = catalog.entries[index]
            if let id = entry.wallpaperID, let wallpaper = try? layouts.wallpaper(id) { return (id, wallpaper) }
            guard let source = entry.pictureID else { throw WallpaperError.unreadable }
            let id = UUID()
            let wallpaper = try WallpaperStore(url: layouts.assetURL(id)).importImage(try layouts.picture(source))
            catalog.entries[index].files.insert(ResourceFile(id: id, role: .wallpaper), at: 0)
            try save(catalog)
            return (id, wallpaper)
        }
    }

    func recordUse(of assetID: UUID) throws {
        try locked {
            var catalog = try load()
            guard let index = catalog.entries.firstIndex(where: { $0.assetIDs.contains(assetID) }) else {
                throw LayoutLibraryError.message("找不到这项资源，请重新导入。")
            }
            catalog.entries[index].lastUsedAt = Date()
            if catalog.entries[index].kind == .model { catalog.entries[index].preferredModelID = assetID }
            try save(catalog)
        }
    }

    func setFavorite(_ favorite: Bool, id: UUID) throws {
        try locked {
            var catalog = try load()
            guard let index = catalog.entries.firstIndex(where: { $0.id == id }) else { return }
            catalog.entries[index].favorite = favorite
            try save(catalog)
        }
    }

    func delete(_ id: UUID, protecting protectedIDs: Set<UUID>) throws {
        try locked {
            var catalog = try load()
            guard let entry = catalog.entries.first(where: { $0.id == id }) else { return }
            guard entry.assetIDs.isDisjoint(with: protectedIDs) else {
                throw LayoutLibraryError.message("这项资源仍被布局或恢复备份使用，请先替换对应素材。")
            }
            catalog.entries.removeAll { $0.id == id }
            catalog.deletedAssetIDs.formUnion(entry.assetIDs)
            try save(catalog)
            for assetID in entry.assetIDs {
                let url = layouts.assetURL(assetID)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            let thumbnail = thumbnails.appendingPathComponent("\(id.uuidString).png")
            if FileManager.default.fileExists(atPath: thumbnail.path) { try FileManager.default.removeItem(at: thumbnail) }
        }
    }

    func size(of entry: SavedResource) -> Int64 {
        entry.assetIDs.reduce(0) { $0 + Int64((try? layouts.assetURL($1).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clearThumbnailCache() throws {
        try locked {
            for directory in [thumbnails, layouts.root.appendingPathComponent("Thumbnails")] {
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            }
        }
    }

    func collectUnusedAssets(in library: LayoutLibrary) {
        locked {
            // Hold the same lock as imports from discovery through deletion, so a freshly
            // written asset cannot be collected before its catalog transaction completes.
            guard let references = try? layouts.referencedAssetIDs(in: library), let catalog = try? load() else { return }
            let used = references.union(catalog.assetIDs)
            let directory = layouts.root.appendingPathComponent("Assets")
            for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !used.contains(id) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}
