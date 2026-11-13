import XCTest
import ImageIO
@testable import DeskIsle

final class ResourceLibraryTests: XCTestCase {
    private var root: URL!
    private var store: LayoutLibraryStore { LayoutLibraryStore(root: root.appendingPathComponent("Layouts")) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("deskisle-resources-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func image(_ name: String = "image.png", gray: CGFloat = 0.6) throws -> URL {
        let context = CGContext(data: nil, width: 80, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 100))
        let url = root.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testOneImageServesPicturesAndWallpaperAfterOriginalIsRemoved() throws {
        let url = try image()
        let original = try Data(contentsOf: url)
        let picture = try store.storePicture(PictureFile(from: url))
        let (wallpaper, prepared) = try store.importWallpaper(from: url)
        XCTAssertNotNil(prepared.portrait)
        let renamed = root.appendingPathComponent("renamed.png")
        try original.write(to: renamed)
        XCTAssertEqual(try store.storePicture(PictureFile(from: renamed)), picture)
        XCTAssertEqual(try store.importWallpaper(from: renamed).0, wallpaper)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.removeItem(at: renamed)
        let catalog = try store.resources.load()
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertEqual(catalog.entries[0].assetIDs, [picture, wallpaper])
        XCTAssertEqual(try store.picture(picture).data, original)
        XCTAssertNotNil(try store.resources.wallpaper(for: catalog.entries[0].id).1.landscape)
    }

    func testFavoritesAndLastSelectionSurviveRestartAndLayoutGarbageCollection() throws {
        let id = try store.storePicture(PictureFile(from: image()))
        let entry = try XCTUnwrap(store.resources.load().entries.first)
        try store.resources.setFavorite(true, id: entry.id)
        try store.resources.recordUse(of: id)
        store.collectUnusedAssets(in: LayoutLibrary())
        let restarted = LayoutLibraryStore(root: store.root)
        let saved = try XCTUnwrap(restarted.resources.load().entries.first)
        XCTAssertEqual(saved.id, entry.id)
        XCTAssertTrue(saved.favorite)
        XCTAssertNotNil(saved.lastUsedAt)
        XCTAssertEqual(saved.pictureID, id)
        XCTAssertNoThrow(try restarted.picture(id))
    }

    func testLegacyDiscoveryGroupsDuplicatesAndPreservesLayoutIDs() throws {
        let file = try PictureFile(from: image())
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let first = try store.storeAsset(encoder.encode(file))
        let second = try store.storeAsset(encoder.encode(file))
        let legacyWallpaper = root.appendingPathComponent("old-wallpaper.plist")
        _ = try WallpaperStore(url: legacyWallpaper).importImage(file)
        let wallpaper = try store.storeAsset(Data(contentsOf: legacyWallpaper))
        let catalog = try store.resources.load()
        XCTAssertEqual(catalog.entries.count, 2)
        XCTAssertEqual(catalog.entries.first { $0.kind == .image }?.assetIDs, [first, second])
        XCTAssertEqual(catalog.entries.first { $0.kind == .wallpaper }?.wallpaperID, wallpaper)
        XCTAssertNil(catalog.entries.first { $0.kind == .wallpaper }?.pictureID)
        XCTAssertTrue(catalog.entries.allSatisfy { $0.lastUsedAt == nil })
        store.collectUnusedAssets(in: LayoutLibrary())
        XCTAssertNoThrow(try store.picture(first))
        XCTAssertNoThrow(try store.picture(second))
        XCTAssertNotNil(try store.wallpaper(wallpaper).portrait)
        XCTAssertEqual(try store.resources.load().entries.map(\.id), catalog.entries.map(\.id))
    }

    func testModelVariantsShareOneEntryAndRememberSelectedQuality() throws {
        let smooth = try BuiltInModel3D.bb8.load()
        let smoothID = try store.storeModel(smooth)
        XCTAssertEqual(try store.storeModel(smooth), smoothID)
        let original = try Model3DFile(source: smooth.source, name: "different name", quality: .original)
        let originalID = try store.storeModel(original)
        XCTAssertNotEqual(originalID, smoothID)
        try store.resources.recordUse(of: originalID)
        let catalog = try store.resources.load()
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertEqual(catalog.entries[0].modelID, originalID)
        XCTAssertEqual(catalog.entries[0].assetIDs, [smoothID, originalID])
        XCTAssertEqual(try store.model(originalID).source, smooth.source)
        XCTAssertEqual(try store.model(smoothID).quality, .smooth)
    }

    func testDeleteProtectsAllVariantsAndBackupReferences() throws {
        let id = try store.storePicture(PictureFile(from: image()))
        let entry = try XCTUnwrap(store.resources.load().entries.first)
        let scene = LayoutScene(layout: ScreenLayout.factory(), pictureIDs: [Component.pictureIDs.lowerBound: id], skinID: "")
        var library = LayoutLibrary(layouts: [SavedLayout(name: "Test", scene: scene)])
        try store.save(library)
        library.layouts[0].scene.pictureIDs = [:]
        try store.save(library)
        XCTAssertThrowsError(try store.resources.delete(entry.id, protecting: store.referencedAssetIDs(in: library)))
        XCTAssertNoThrow(try store.picture(id))
        try store.save(library)
        try store.resources.delete(entry.id, protecting: store.referencedAssetIDs(in: library))
        XCTAssertTrue(try store.resources.load().entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.assetURL(id).path))
    }

    func testDeletedFilesAreNotRediscoveredAndCanBeImportedAgain() throws {
        let url = try image()
        let id = try store.storePicture(PictureFile(from: url))
        let bytes = try Data(contentsOf: store.assetURL(id))
        let entry = try XCTUnwrap(store.resources.load().entries.first)
        try store.resources.delete(entry.id, protecting: [])
        // Simulate an interrupted removal leaving an old payload on disk.
        try bytes.write(to: store.assetURL(id))
        XCTAssertTrue(try store.resources.load().entries.isEmpty)
        let replacement = try store.storePicture(PictureFile(from: url))
        XCTAssertNotEqual(replacement, id)
        XCTAssertEqual(try store.resources.load().entries.count, 1)
    }

    func testCorruptCatalogFailsClosedAndUnknownVersionCannotDowngrade() throws {
        let id = try store.storePicture(PictureFile(from: image()))
        let entry = try XCTUnwrap(store.resources.load().entries.first)
        try store.resources.setFavorite(true, id: entry.id) // Creates a recoverable backup.
        try Data("broken".utf8).write(to: store.resources.manifest)
        XCTAssertEqual(try store.resources.load().entries.first?.id, entry.id)
        var future = try store.resources.load(); future.version = 999
        try JSONEncoder().encode(future).write(to: store.resources.manifest)
        XCTAssertThrowsError(try store.resources.load())
        store.collectUnusedAssets(in: LayoutLibrary())
        XCTAssertNoThrow(try store.picture(id))
        try FileManager.default.removeItem(at: store.resources.backup)
        try Data("broken".utf8).write(to: store.resources.manifest)
        XCTAssertThrowsError(try store.resources.setFavorite(false, id: entry.id))
        store.collectUnusedAssets(in: LayoutLibrary())
        XCTAssertNoThrow(try store.picture(id))
    }

    func testReimportRepairsMissingOriginalWithoutDuplicatingEntry() throws {
        let url = try image()
        let id = try store.storePicture(PictureFile(from: url))
        let entry = try XCTUnwrap(store.resources.load().entries.first)
        try store.resources.setFavorite(true, id: entry.id)
        try FileManager.default.removeItem(at: store.assetURL(id))
        let repaired = try store.storePicture(PictureFile(from: url))
        let catalog = try store.resources.load()
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertEqual(catalog.entries.first?.id, entry.id)
        XCTAssertTrue(catalog.entries.first!.favorite)
        XCTAssertEqual(catalog.entries.first?.pictureID, repaired)
        XCTAssertNoThrow(try store.picture(repaired))
    }

    func testCacheCleanupKeepsOriginalsFavoritesAndDerivedWallpaper() throws {
        let (wallpaper, _) = try store.importWallpaper(from: image())
        let entry = try XCTUnwrap(store.resources.load().entries.first)
        try store.resources.setFavorite(true, id: entry.id)
        try FileManager.default.createDirectory(at: store.resources.thumbnails, withIntermediateDirectories: true)
        try Data("cached preview".utf8).write(to: store.resources.thumbnails.appendingPathComponent("preview.png"))
        try store.resources.clearThumbnailCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.resources.thumbnails.path))
        XCTAssertNoThrow(try store.picture(entry.pictureID!))
        XCTAssertNotNil(try store.wallpaper(wallpaper).landscape)
        XCTAssertTrue(try store.resources.load().entries.first!.favorite)
    }

    func testConcurrentImportsDoNotDuplicateOrLoseFavorites() throws {
        let file = try PictureFile(from: image())
        let store = self.store
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            _ = try? store.storePicture(file)
        }
        let catalog = try store.resources.load()
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertEqual(catalog.entries[0].files.count, 1)
        XCTAssertNoThrow(try store.picture(catalog.entries[0].pictureID!))
    }
}
