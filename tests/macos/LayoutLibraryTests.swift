import XCTest
import ImageIO
@testable import DeskIsle

private actor LibraryDeviceStub: LayoutDevice {
    var layout = ScreenLayout(panel: .deskIsle, direction: .portrait, components: [])
    var status = 0
    var offline = false
    var failWallpaper = false
    var transientFailures = 0
    var delay: Duration = .zero
    var applications: [ScreenLayout] = []
    var wallpapers: [UInt32] = []

    func configure(status: Int = 0, offline: Bool = false, failWallpaper: Bool = false, delay: Duration = .zero) {
        self.status = status; self.offline = offline; self.failWallpaper = failWallpaper; self.delay = delay
    }
    func readLayout() throws -> LayoutReply? { offline ? nil : reply() }
    func apply(_ value: ScreenLayout) async throws -> LayoutReply {
        if delay != .zero { try await Task.sleep(for: delay) }
        if offline { throw LayoutLibraryError.message("disconnected") }
        applications.append(value)
        if status == 0 || status == 3 { layout = value }
        return reply()
    }
    func failNextUpload() { transientFailures = 1 }
    func showWallpaper(_ image: WallpaperFrame, for panel: Panel) throws -> Bool {
        if transientFailures > 0 {
            transientFailures -= 1
            throw LayoutUSBError.message("transient serial interruption")
        }
        if failWallpaper { throw LayoutLibraryError.message("wallpaper interrupted") }
        wallpapers.append(image.upload(supportsLandscape: true, limit: 512 * 1024).checksum)
        return true
    }
    private func reply() -> LayoutReply {
        let components = layout.components.flatMap { [$0.id, $0.x, $0.y, $0.width, $0.height] }
        let numbers = [status, 720, 1280, 10, 1_843_200, 98_304, layout.direction.rawValue, layout.components.count] + components
        return LayoutReply(line: "DESKISLE_LAYOUT 1 123 " + numbers.map(String.init).joined(separator: " "), sequence: 123, widgetVersion: 2)!
    }
}

private actor PictureTransportStub: PictureFrameTransport {
    var started = false
    var finished = false
    var cancelled = false
    func showFrame(_ jpeg: Data, alphaMask: Data?, for component: Component, maxJPEG: Int) async throws -> Bool {
        started = true
        do { try await Task.sleep(for: .milliseconds(100)) }
        catch { cancelled = true; throw error }
        finished = true
        return true
    }
}

@MainActor
final class LayoutLibraryTests: XCTestCase {
    private var roots: [URL] = []
    private var domains: [String] = []

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deskisle-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }
    private func cleanup() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        for domain in domains { UserDefaults.standard.removePersistentDomain(forName: domain) }
        roots = []; domains = []
    }
    private func editor(_ root: URL, device: LibraryDeviceStub = LibraryDeviceStub()) -> LayoutEditor {
        let domain = "deskisle.library.tests.\(UUID().uuidString)"
        domains.append(domain)
        let preferences = UserDefaults(suiteName: domain)!
        preferences.set(false, forKey: "pet.enabled")
        let usb = LayoutUSB()
        return LayoutEditor(usb: usb, displaySettings: DisplaySettings(usb: usb, preferences: preferences),
                            connections: ConnectionSettings(preferences: preferences, inspectConnections: false),
                            petSettings: PetSettings(usb: usb, preferences: preferences, importLegacySettings: false),
                            libraryStore: LayoutLibraryStore(root: root), device: device)
    }
    private func jpeg(_ color: CGFloat = 0.3) throws -> Data {
        let context = CGContext(data: nil, width: 720, height: 1280, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: color, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 720, height: 1280))
        let data = NSMutableData()
        let output = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(output, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        return data as Data
    }
    private func scene(_ store: LayoutLibraryStore, direction: ScreenDirection = .portrait, color: CGFloat = 0.3) throws -> LayoutScene {
        let image = store.root.appendingPathComponent("input-\(UUID().uuidString).jpg")
        try jpeg(color).write(to: image)
        let (id, _) = try store.importWallpaper(from: image)
        return LayoutScene(layout: ScreenLayout(panel: .deskIsle, direction: direction, components: []), wallpaperID: id, skinID: "")
    }
    private func seed(_ editor: LayoutEditor, scene: LayoutScene) async -> SavedLayout {
        let profile = SavedLayout(name: "日常", scene: scene)
        editor.library = LayoutLibrary(migrated: true, layouts: [profile], editingID: profile.id)
        await editor.loadForEditing(profile)
        XCTAssertTrue(editor.flushLayoutSave())
        return profile
    }

    func testLibraryCRUDAndImmutableCopies() async throws {
        defer { cleanup() }
        let editor = editor(try root())
        let original = await seed(editor, scene: try scene(editor.libraryStore))
        await editor.createLayout(copying: original.id)
        let copy = try XCTUnwrap(editor.editingProfile)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.scene, original.scene)
        XCTAssertNil(editor.library.requested, "Creating a copy must not change the device")
        editor.changeDirection(.left)
        XCTAssertEqual(editor.library.layouts.first?.scene, original.scene)
        editor.renameLayout(copy.id, to: "  工作  ")
        XCTAssertEqual(editor.editingProfile?.name, "工作")
        XCTAssertTrue(editor.flushLayoutSave())
        let restored = try editor.libraryStore.load().library
        XCTAssertEqual(restored.layouts.count, 2)
        XCTAssertEqual(restored.layouts.last?.scene.layout.direction, .left)
        await editor.deleteLayout(copy.id)
        XCTAssertEqual(editor.library.layouts.count, 1)
        XCTAssertFalse(editor.library.canDelete(original.id))
    }

    func testBackupRecoveryAndUnknownSchemaProtection() throws {
        defer { cleanup() }
        let store = LayoutLibraryStore(root: try root())
        let profile = SavedLayout(name: "first", scene: try scene(store))
        var library = LayoutLibrary(migrated: true, layouts: [profile])
        try store.save(library)
        library.layouts[0].name = "second"
        try store.save(library)
        try Data("broken".utf8).write(to: store.manifest)
        let loaded = try store.load()
        XCTAssertTrue(loaded.recovered)
        XCTAssertEqual(loaded.library.layouts[0].name, "first")
        try store.save(loaded.library)
        XCTAssertEqual(try store.decode(Data(contentsOf: store.backup)).layouts[0].name, "first")
        library.version = 99
        try JSONEncoder().encode(library).write(to: store.manifest)
        XCTAssertThrowsError(try store.load())
    }

    func testFailedSaveRetainsEditsAndStopsSelection() async throws {
        defer { cleanup() }
        let editor = editor(try root())
        let first = await seed(editor, scene: try scene(editor.libraryStore))
        await editor.createLayout(copying: first.id)
        let copy = editor.library.editingID
        editor.changeDirection(.left)
        try FileManager.default.removeItem(at: editor.libraryStore.manifest)
        try FileManager.default.createDirectory(at: editor.libraryStore.manifest, withIntermediateDirectories: true)
        XCTAssertFalse(editor.flushLayoutSave())
        XCTAssertNotNil(editor.libraryError)
        await editor.selectLayout(first.id)
        XCTAssertEqual(editor.library.editingID, copy)
        XCTAssertEqual(editor.draft.direction, .left)
    }

    func testOfflineRequestUsesSnapshotNotLaterDraftAndProtectsDeletion() async throws {
        defer { cleanup() }
        let editor = editor(try root())
        let first = await seed(editor, scene: try scene(editor.libraryStore))
        await editor.selectLayout(first.id)
        XCTAssertTrue(editor.syncPending)
        XCTAssertEqual(editor.library.requested?.scene, first.scene)
        editor.changeDirection(.left)
        XCTAssertTrue(editor.flushLayoutSave())
        let restored = try editor.libraryStore.load().library
        XCTAssertEqual(restored.requested?.scene.layout.direction, .portrait)
        XCTAssertEqual(restored.layouts[0].scene.layout.direction, .left)
        XCTAssertFalse(restored.canDelete(first.id))
    }

    func testSameComponentIDDifferentAssetsAndAppliedIsolation() async throws {
        defer { cleanup() }
        let editor = editor(try root())
        var first = try scene(editor.libraryStore)
        let id = Component.pictureIDs.lowerBound
        let component = Component(id: id, x: 0, y: 0, width: 160, height: 160)
        first.layout.components = [component]
        let a = editor.libraryStore.root.appendingPathComponent("a.jpg")
        let b = editor.libraryStore.root.appendingPathComponent("b.jpg")
        try jpeg(0.1).write(to: a); try jpeg(0.9).write(to: b)
        first.pictureIDs[id] = try editor.libraryStore.storePicture(PictureFile(from: a))
        let original = await seed(editor, scene: first)
        editor.pictureRuntime.appliedPictures = editor.pictureRuntime.pictures
        let displayedAsset = editor.pictureRuntime.appliedPictures[id]?.id
        await editor.createLayout(copying: original.id)
        let file = try PictureFile(from: b)
        try editor.storePicture(file, asset: PictureAsset.prepare(file), replacing: id)
        XCTAssertNotEqual(editor.editingScene.pictureIDs[id], first.pictureIDs[id])
        XCTAssertEqual(editor.pictureRuntime.appliedPictures[id]?.id, displayedAsset)
        XCTAssertNotEqual(editor.pictureRuntime.pictures[id]?.id, displayedAsset)
        XCTAssertEqual(try editor.libraryStore.picture(first.pictureIDs[id]!).data, try Data(contentsOf: a))
    }

    func testMigrationCapturesDeviceBeforeOfflineRequestAndRunsOnce() async throws {
        defer { cleanup() }
        let base = try root()
        let editor = editor(base.appendingPathComponent("Layouts"))
        try FileManager.default.createDirectory(at: editor.libraryStore.root, withIntermediateDirectories: true)
        let input = base.appendingPathComponent("input.jpg")
        try jpeg().write(to: input)
        _ = try WallpaperStore(url: base.appendingPathComponent("Wallpaper.plist")).importImage(from: input)
        let before = try Data(contentsOf: base.appendingPathComponent("Wallpaper.plist"))
        let offline = await seed(editor, scene: try scene(editor.libraryStore, direction: .left))
        editor.library.migrated = false
        await editor.selectLayout(offline.id)
        let original = ScreenLayout.factory()
        try await editor.migrateLegacyLayout(original)
        try await editor.migrateLegacyLayout(original)
        XCTAssertEqual(editor.library.layouts.count, 2)
        XCTAssertEqual(editor.library.layouts[0].scene.layout, original)
        XCTAssertEqual(editor.library.requested?.id, offline.id)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("Wallpaper.plist")), before)
        XCTAssertNotNil(editor.library.layouts[0].scene.wallpaperID)
    }

    func testMissingAssetAndSkinRejectBeforeDeviceMutation() async throws {
        defer { cleanup() }
        let device = LibraryDeviceStub()
        let editor = editor(try root(), device: device)
        var missing = try scene(editor.libraryStore)
        missing.wallpaperID = UUID()
        _ = await seed(editor, scene: missing)
        editor.connected = true; editor.widgetVersion = 2
        await editor.apply()
        XCTAssertTrue(editor.notice.contains("未完全同步"))
        let applicationCount = await device.applications.count
        XCTAssertEqual(applicationCount, 0)
        var skin = try scene(editor.libraryStore)
        skin.layout.components = [Component.pet(in: skin.layout.grid)!]
        skin.skinID = "missing-skin"
        _ = await seed(editor, scene: skin)
        await editor.apply()
        XCTAssertTrue(editor.notice.contains("皮肤不可用"))
        let afterSkin = await device.applications.count
        XCTAssertEqual(afterSkin, 0)
    }

    func testApplyFailureRetryPersistenceStatusAndReconnectSnapshot() async throws {
        defer { cleanup() }
        let device = LibraryDeviceStub()
        let editor = editor(try root(), device: device)
        let first = await seed(editor, scene: try scene(editor.libraryStore, direction: .left))
        editor.connected = true; editor.widgetVersion = 2
        await device.configure(failWallpaper: true)
        await editor.selectLayout(first.id)
        XCTAssertTrue(editor.syncPending)
        XCTAssertNil(editor.library.displayed)
        await device.configure(status: 3)
        await editor.synchronizeRequestedScene()
        XCTAssertTrue(editor.unsaved)
        XCTAssertEqual(editor.library.displayed?.id, first.id)
        await device.configure()
        await editor.synchronizeRequestedScene()
        XCTAssertFalse(editor.syncPending)
        editor.changeDirection(.portrait)
        editor.flushLayoutSave()
        await device.configure(offline: true)
        await editor.refresh()
        XCTAssertFalse(editor.connected)
        await device.configure()
        await editor.refresh()
        let deviceDirection = await device.layout.direction
        XCTAssertEqual(deviceDirection, .left)
        XCTAssertEqual(editor.draft.direction, .portrait)
    }

    func testRapidSwitchLastRequestWins() async throws {
        defer { cleanup() }
        let device = LibraryDeviceStub()
        let editor = editor(try root(), device: device)
        let a = await seed(editor, scene: try scene(editor.libraryStore))
        let b = SavedLayout(name: "横屏", scene: try scene(editor.libraryStore, direction: .left, color: 0.7))
        editor.library.layouts.append(b)
        editor.connected = true; editor.widgetVersion = 2
        await device.configure(delay: .milliseconds(80))
        let first = Task { await editor.selectLayout(a.id) }
        try await Task.sleep(for: .milliseconds(30))
        let second = Task { await editor.selectLayout(b.id) }
        await first.value; await second.value
        XCTAssertEqual(editor.library.displayed?.id, b.id)
        let deviceDirection = await device.layout.direction
        XCTAssertEqual(deviceDirection, .left)
        XCTAssertFalse(editor.applying)
    }

    func testRestartRestoresRequestedSceneWithoutApplyingSavedEdits() async throws {
        defer { cleanup() }
        let root = try root()
        let firstDevice = LibraryDeviceStub()
        let original = editor(root, device: firstDevice)
        let profile = await seed(original, scene: try scene(original.libraryStore, direction: .left))
        original.connected = true; original.widgetVersion = 2
        await original.selectLayout(profile.id)
        original.changeDirection(.portrait)
        original.flushLayoutSave()
        let nextDevice = LibraryDeviceStub()
        let restarted = editor(root, device: nextDevice)
        await restarted.refresh()
        let direction = await nextDevice.layout.direction
        XCTAssertEqual(direction, .left)
        XCTAssertEqual(restarted.editingProfile?.scene.layout.direction, .portrait)
        XCTAssertTrue(restarted.hasChanges)
    }

    func testRepeatedSwitchesReleasePreparedPicturesAndLeaveNoWorker() async throws {
        defer { cleanup() }
        let device = LibraryDeviceStub()
        let editor = editor(try root(), device: device)
        let a = await seed(editor, scene: try scene(editor.libraryStore))
        let b = SavedLayout(name: "另一套", scene: try scene(editor.libraryStore, direction: .left))
        editor.library.layouts.append(b)
        editor.connected = true; editor.widgetVersion = 2
        for index in 0..<20 {
            await editor.selectLayout(index.isMultiple(of: 2) ? a.id : b.id)
            XCTAssertNil(editor.synchronization)
            XCTAssertFalse(editor.applying)
        }
        let applications = await device.applications.count
        XCTAssertEqual(applications, 20)
        XCTAssertTrue(editor.pictureRuntime.pictures.isEmpty)
        XCTAssertTrue(editor.pictureRuntime.appliedPictures.isEmpty)
        XCTAssertEqual(editor.library.layouts.count, 2)
    }

    func testRejectedGeometryAndUnpersistedRequestCannotReplaceActiveSnapshot() async throws {
        defer { cleanup() }
        let device = LibraryDeviceStub()
        let editor = editor(try root(), device: device)
        let a = await seed(editor, scene: try scene(editor.libraryStore))
        editor.connected = true; editor.widgetVersion = 2
        await editor.selectLayout(a.id)
        let b = SavedLayout(name: "另一套", scene: try scene(editor.libraryStore, direction: .left))
        editor.library.layouts.append(b)
        await device.configure(status: 1)
        await editor.selectLayout(b.id)
        XCTAssertEqual(editor.library.displayed?.id, a.id)
        XCTAssertTrue(editor.syncPending)
        let requested = editor.library.requested
        try FileManager.default.removeItem(at: editor.libraryStore.manifest)
        try FileManager.default.createDirectory(at: editor.libraryStore.manifest, withIntermediateDirectories: true)
        await editor.requestScene(LayoutSelection(id: a.id, scene: a.scene))
        XCTAssertEqual(editor.library.requested, requested)
        XCTAssertNotNil(editor.libraryError)
    }

    func testPausingGIFDrainsCurrentSerialFrameWithoutCancellation() async throws {
        defer { cleanup() }
        let directory = try root()
        let url = directory.appendingPathComponent("test.gif")
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 2, nil)!
        for color in [CGFloat(0.1), CGFloat(0.9)] {
            let source = CGImageSourceCreateWithData(try jpeg(color) as CFData, nil)!
            CGImageDestinationAddImage(destination, CGImageSourceCreateImageAtIndex(source, 0, nil)!,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
        let asset = try PictureAsset.prepare(PictureFile(from: url))
        XCTAssertTrue(asset.isAnimated)
        let transport = PictureTransportStub()
        let runtime = PictureRuntime(usb: transport)
        let component = Component(id: Component.pictureIDs.lowerBound, x: 0, y: 0, width: 160, height: 160)
        let layout = ScreenLayout(panel: .deskIsle, direction: .portrait, components: [component])
        runtime.context = { WidgetContext(draft: layout, applied: layout, connected: true, applying: false, revision: 0) }
        runtime.appliedPictures = [component.id: asset]
        runtime.updatePicturePlayback()
        for _ in 0..<100 {
            if await transport.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await runtime.pausePlayback()
        let completed = await transport.finished
        let cancelled = await transport.cancelled
        XCTAssertTrue(completed, "A frame already on the wire must finish before layout switching")
        XCTAssertFalse(cancelled, "Cancelling a partial JPEG destroys the shared USB control session")
    }

    func testInterruptedTransferReconnectsBeforeRetryingSnapshot() async throws {
        defer { cleanup() }
        let device = LibraryDeviceStub()
        let editor = editor(try root(), device: device)
        let profile = await seed(editor, scene: try scene(editor.libraryStore))
        editor.connected = true; editor.widgetVersion = 2
        await device.failNextUpload()
        await editor.selectLayout(profile.id)
        XCTAssertEqual(editor.library.displayed?.id, profile.id)
        XCTAssertFalse(editor.syncPending)
        let applications = await device.applications.count
        XCTAssertEqual(applications, 2)
    }

    func testPetNotReadyCannotMarkFullSceneApplied() async throws {
        defer { cleanup() }
        let editor = editor(try root())
        var scene = try scene(editor.libraryStore)
        scene.layout.components = [Component.pet(in: scene.layout.grid)!]
        scene.skinID = editor.petSettings.selectedID
        let profile = await seed(editor, scene: scene)
        let selection = LayoutSelection(id: profile.id, scene: scene)
        editor.library.requested = selection
        editor.deviceReady = true
        editor.petSettings.setEnabled(true)
        editor.pendingPetSelection = selection
        editor.completePendingPet(active: false)
        XCTAssertNil(editor.library.displayed)
        XCTAssertNotNil(editor.pendingPetSelection)
        editor.petSettings.setEnabled(false)
        XCTAssertEqual(editor.library.displayed, selection)
        XCTAssertNil(editor.pendingPetSelection)
    }

    func testMalformedPanelIsRejectedBeforeGeometryValidation() throws {
        defer { cleanup() }
        let store = LayoutLibraryStore(root: try root())
        let panel = Panel(nativeWidth: -1, nativeHeight: 1280, maxComponents: 1000, maxPixels: 1, maxJPEG: 1)
        let scene = LayoutScene(layout: ScreenLayout(panel: panel, direction: .portrait, components: []), skinID: "")
        let library = LayoutLibrary(layouts: [SavedLayout(name: "bad", scene: scene)])
        XCTAssertThrowsError(try store.decode(JSONEncoder().encode(library)))
    }

    func testGarbageCollectionPreservesBackupAndDisplayReferences() throws {
        defer { cleanup() }
        let store = LayoutLibraryStore(root: try root())
        let profile = SavedLayout(name: "first", scene: try scene(store))
        var library = LayoutLibrary(migrated: true, layouts: [profile])
        try store.save(library)
        let original = profile.scene.wallpaperID!
        library.layouts[0].scene.wallpaperID = nil
        try store.save(library)
        let unused = try store.storeAsset(Data("unused".utf8))
        store.collectUnusedAssets(in: library)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.assetURL(original).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.assetURL(unused).path))
    }
}
