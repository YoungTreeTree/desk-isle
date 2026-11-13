import Foundation

struct LayoutScene: Codable, Equatable, Sendable {
    var layout: ScreenLayout
    var wallpaperID: UUID?
    var pictureIDs: [Int: UUID] = [:]
    var skinID: String
}

struct SavedLayout: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var scene: LayoutScene
    var updatedAt = Date()
}

struct LayoutSelection: Codable, Equatable, Sendable {
    var id: UUID
    var scene: LayoutScene
}

struct LayoutLibrary: Codable, Sendable {
    var version = 1
    var migrated = false
    var layouts: [SavedLayout] = []
    var editingID: UUID?
    // This is an immutable request snapshot, not a reference to the latest edited version.
    var requested: LayoutSelection?
    var displayed: LayoutSelection?

    func canDelete(_ id: UUID) -> Bool {
        layouts.count > 1 && requested?.id != id && displayed?.id != id
    }

    func uniqueName(_ base: String) -> String {
        let names = Set(layouts.map(\.name))
        if !names.contains(base) { return base }
        var number = 2
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}

enum LayoutLibraryError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

struct LayoutLibraryStore: Sendable {
    let root: URL
    var manifest: URL { root.appendingPathComponent("Library.json") }
    var backup: URL { root.appendingPathComponent("Library.backup.json") }

    static var local: Self {
        Self(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.deskisle.layout/Layouts", isDirectory: true))
    }

    func decode(_ bytes: Data) throws -> LayoutLibrary {
        let result = try JSONDecoder().decode(LayoutLibrary.self, from: bytes)
        guard result.version == 1 else { throw LayoutLibraryError.message("布局库版本不受支持，请更新桌屿。") }
        func valid(_ scene: LayoutScene) -> Bool {
            let panel = scene.layout.panel
            guard (512...4096).contains(panel.nativeWidth), (512...4096).contains(panel.nativeHeight),
                  (1...64).contains(panel.maxComponents), panel.maxPixels > 0, panel.maxJPEG > 0 else { return false }
            return scene.layout.isValid
        }
        let ids = Set(result.layouts.map(\.id))
        guard ids.count == result.layouts.count,
              result.layouts.allSatisfy({ valid($0.scene) }),
              result.requested.map({ ids.contains($0.id) && valid($0.scene) }) ?? true,
              result.displayed.map({ ids.contains($0.id) && valid($0.scene) }) ?? true else {
            throw LayoutLibraryError.message("布局库内容损坏，未覆盖原文件。")
        }
        return result
    }

    func load() throws -> (library: LayoutLibrary, recovered: Bool) {
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            if FileManager.default.fileExists(atPath: backup.path) {
                return (try decode(Data(contentsOf: backup)), true)
            }
            return (LayoutLibrary(), false)
        }
        do { return (try decode(Data(contentsOf: manifest)), false) }
        catch {
            // Never downgrade an unknown future schema through an older backup.
            if let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
               let version = object["version"] as? Int, version != 1 { throw error }
            if let bytes = try? Data(contentsOf: backup), let library = try? decode(bytes) {
                return (library, true)
            }
            throw error
        }
    }

    func save(_ library: LayoutLibrary) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(library)
        _ = try decode(bytes)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Only back up valid data. A recovered copy must not be replaced with corrupt bytes.
        if let previous = try? Data(contentsOf: manifest), (try? decode(previous)) != nil {
            try previous.write(to: backup, options: .atomic)
        }
        try bytes.write(to: manifest, options: .atomic)
    }

    func assetURL(_ id: UUID) -> URL { root.appendingPathComponent("Assets/\(id.uuidString).plist") }

    func storeAsset(_ bytes: Data, id: UUID = UUID()) throws -> UUID {
        let url = assetURL(id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        return id
    }

    func storePicture(_ file: PictureFile) throws -> UUID {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try storeAsset(encoder.encode(file))
    }

    func picture(_ id: UUID) throws -> PictureFile {
        try PropertyListDecoder().decode(PictureFile.self, from: Data(contentsOf: assetURL(id)))
    }

    func wallpaper(_ id: UUID?) throws -> ScreenWallpaper {
        guard let id else { return .bundled }
        return try WallpaperStore(url: assetURL(id)).loadRequired()
    }

    func importWallpaper(from source: URL) throws -> (UUID, ScreenWallpaper) {
        let id = UUID()
        let wallpaper = try WallpaperStore(url: assetURL(id)).importImage(from: source)
        return (id, wallpaper)
    }

    func validateReferences(_ scene: LayoutScene) throws {
        if let id = scene.wallpaperID, !FileManager.default.fileExists(atPath: assetURL(id).path) {
            throw LayoutLibraryError.message("壁纸文件缺失，请更换壁纸。")
        }
        for component in scene.layout.components where component.isPicture {
            guard let id = scene.pictureIDs[component.id], FileManager.default.fileExists(atPath: assetURL(id).path) else {
                throw LayoutLibraryError.message("图片组件缺少文件，请重新选取图片。")
            }
        }
    }

    func prepare(_ scene: LayoutScene) throws -> PreparedLayoutScene {
        let wallpaper = try wallpaper(scene.wallpaperID)
        var pictures: [Int: PictureAsset] = [:]
        for component in scene.layout.components where component.isPicture {
            guard let id = scene.pictureIDs[component.id] else {
                throw LayoutLibraryError.message("图片组件缺少文件，请重新选取图片。")
            }
            do { pictures[component.id] = try PictureAsset.prepare(picture(id)) }
            catch { throw LayoutLibraryError.message("无法读取图片组件的文件，请更换图片。") }
        }
        return PreparedLayoutScene(wallpaper: wallpaper, pictures: pictures)
    }

    // Keep references from both the current manifest and its recoverable backup.
    func collectUnusedAssets(in library: LayoutLibrary) {
        var scenes = library.layouts.map(\.scene) + [library.requested?.scene, library.displayed?.scene].compactMap { $0 }
        if let bytes = try? Data(contentsOf: backup), let old = try? decode(bytes) {
            scenes += old.layouts.map(\.scene) + [old.requested?.scene, old.displayed?.scene].compactMap { $0 }
        }
        let used = Set(scenes.flatMap { Array($0.pictureIDs.values) + [$0.wallpaperID].compactMap { $0 } })
        let directory = root.appendingPathComponent("Assets")
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !used.contains(id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

struct PreparedLayoutScene: Sendable {
    let wallpaper: ScreenWallpaper
    let pictures: [Int: PictureAsset]
}
