import Foundation

extension LayoutEditor {
    var editingProfile: SavedLayout? { library.layouts.first { $0.id == library.editingID } }
    var editingScene: LayoutScene {
        let used = Set(draft.components.filter(\.isPicture).map(\.id))
        return LayoutScene(layout: draft, wallpaperID: draftWallpaperID,
                           pictureIDs: draftPictureIDs.filter { used.contains($0.key) }, skinID: petSettings.selectedID,
                           modelID: draft.model3D == nil ? nil : draftModelID,modelScale:draft.model3D == nil ? nil : draftModelScale)
    }
    var libraryBusy: Bool { resourceBusy || importingPicture || importingModel || importingWallpaper || migratingLegacy || libraryReadFailed }

    func recordDraftChange() {
        guard !restoringScene, !libraryReadFailed else { return }
        if library.editingID == nil {
            let profile = SavedLayout(name: library.uniqueName("新布局"), scene: editingScene)
            library.layouts.append(profile)
            library.editingID = profile.id
            petSettings.layoutName = profile.name
        }
        guard let index = library.layouts.firstIndex(where: { $0.id == library.editingID }) else { return }
        if library.layouts[index].scene != editingScene {
            notice = ""
            library.layouts[index].scene = editingScene
            library.layouts[index].updatedAt = Date()
        }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.flushLayoutSave()
        }
    }

    @discardableResult
    func flushLayoutSave() -> Bool {
        saveTask?.cancel(); saveTask = nil
        guard !libraryReadFailed else { return false }
        do {
            try libraryStore.save(library)
            libraryError = nil
            return true
        } catch {
            libraryError = "布局尚未保存到 Mac：\(error.localizedDescription)"
            return false
        }
    }

    func returnToLibrary() {
        _ = flushLayoutSave()
        showingLibrary = true
    }

    @discardableResult
    func loadForEditing(_ profile: SavedLayout, showEditor: Bool = true) async -> Bool {
        editGeneration += 1
        let generation = editGeneration
        loadingLayout = true
        let previous = editPreparation
        previous?.cancel()
        _ = await previous?.value
        guard generation == editGeneration else { return false }
        preparedEditingScene = nil
        restoringScene = true
        library.editingID = profile.id
        draftWallpaperID = profile.scene.wallpaperID
        draftPictureIDs = profile.scene.pictureIDs
        draftModelID = profile.scene.modelID
        draftModelScale = profile.scene.modelScale ?? 1
        modelName = nil
        modelOptimized = false
        modelTriangles = nil
        modelSourceTriangles = nil
        modelStats = nil
        draft = profile.scene.layout
        petSettings.editSkin(profile.scene.skinID, layoutName: profile.name)
        pictureRuntime.pictures = [:]
        wallpaper = .bundled
        selectedID = draft.components.first?.id
        restoringScene = false
        if showEditor { showingLibrary = false }
        let store = libraryStore
        // Load what is readable even if another asset is missing, so users can repair the scene.
        let preparation = Task.detached(priority: .userInitiated) {
            var errors: [String] = []
            let wallpaper: ScreenWallpaper
            do { wallpaper = try store.wallpaper(profile.scene.wallpaperID) }
            catch { wallpaper = .bundled; errors.append("壁纸文件缺失或损坏，请更换壁纸。") }
            var pictures: [Int: PictureAsset] = [:]
            for component in profile.scene.layout.components where component.isPicture {
                if Task.isCancelled { break }
                do {
                    guard let id = profile.scene.pictureIDs[component.id] else { throw PictureError.unreadable }
                    pictures[component.id] = try PictureAsset.prepare(store.picture(id))
                } catch { errors.append("图片组件 \(component.id) 无法读取，请重新选取。") }
            }
            return (wallpaper, pictures, errors.joined(separator: " "))
        }
        editPreparation = preparation
        let result = await preparation.value
        guard generation == editGeneration else { return false }
        editPreparation = nil
        if result.2.isEmpty { preparedEditingScene = profile.scene }
        wallpaper = result.0
        pictureRuntime.pictures = result.1
        notice = result.2
        if draft.components.contains(where: \.isPet), !petSettings.skins.contains(where: { $0.id == profile.scene.skinID }) {
            notice = "桌宠皮肤不可用，请重新选择皮肤。"
        }
        loadingLayout = false
        if let id = profile.scene.modelID {
            // Read once on selection; do not retain a second live copy of the model or a preview renderer.
            let details = await Task.detached(priority:.utility) { () -> (String, Bool, Int, Int)? in
                guard let file=try? store.model(id) else { return nil }
                return (file.name,file.quality == .smooth,file.triangles,file.sourceTriangles ?? file.triangles)
            }.value
            guard generation == editGeneration else { return false }
            modelName = details?.0; modelOptimized = details?.1 ?? false
            modelTriangles = details?.2; modelSourceTriangles = details?.3
        }
        return true
    }

    func selectLayout(_ id: UUID) async {
        guard !libraryBusy, flushLayoutSave(), let profile = library.layouts.first(where: { $0.id == id }) else { return }
        guard await loadForEditing(profile), library.editingID == id, !loadingLayout else { return }
        await requestScene(LayoutSelection(id: id, scene: profile.scene))
    }

    func createLayout(copying id: UUID? = nil) async {
        guard !libraryBusy, !loadingLayout, flushLayoutSave() else { return }
        let source = library.layouts.first { $0.id == id }
        let scene = source?.scene ?? LayoutScene(
            layout: ScreenLayout(panel: draft.panel, direction: draft.direction, components: []), skinID: petSettings.selectedID)
        let profile = SavedLayout(name: library.uniqueName(source.map { "\($0.name) 副本" } ?? "新布局"), scene: scene)
        library.layouts.append(profile)
        await loadForEditing(profile)
        _ = flushLayoutSave()
    }

    func renameLayout(_ id: UUID, to text: String) {
        let name = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty, let index = library.layouts.firstIndex(where: { $0.id == id }) else { return }
        library.layouts[index].name = name
        if library.editingID == id { petSettings.layoutName = name }
        _ = flushLayoutSave()
    }

    func deleteLayout(_ id: UUID) async {
        guard !libraryBusy, !loadingLayout, library.canDelete(id), flushLayoutSave() else { return }
        library.layouts.removeAll { $0.id == id }
        if library.editingID == id, let next = library.layouts.first {
            await loadForEditing(next, showEditor: false)
        }
        if flushLayoutSave() { libraryStore.collectUnusedAssets(in: library) }
    }

    func migrateLegacyLayout(_ layout: ScreenLayout) async throws {
        guard !library.migrated, !libraryReadFailed, !migratingLegacy else { return }
        migratingLegacy = true
        defer { migratingLegacy = false }
        let store = libraryStore
        let skinID = petSettings.legacySkinID
        var profile = try await Task.detached(priority: .utility) {
            var layout = layout.alignedToGrid().upgradingCodexFootprint()
                .upgradingNotificationFootprint().upgradingBluetoothFootprint()
            layout.components.removeAll { $0.id == Component.retiredMusicID }
            var scene = LayoutScene(layout: layout, skinID: skinID)
            let legacy = store.root.deletingLastPathComponent()
            let wallpaperURL = legacy.appendingPathComponent("Wallpaper.plist")
            if FileManager.default.fileExists(atPath: wallpaperURL.path) {
                // Keep the legacy file untouched, including when its contents need repair.
                scene.wallpaperID = try store.storeAsset(Data(contentsOf: wallpaperURL))
            }
            for component in layout.components where component.isPicture {
                let url = legacy.appendingPathComponent("Pictures/\(component.id).plist")
                if let bytes = try? Data(contentsOf: url) { scene.pictureIDs[component.id] = try store.storeAsset(bytes) }
            }
            return SavedLayout(name: "默认布局", scene: scene)
        }.value
        var candidate = library
        profile.name = candidate.uniqueName("默认布局")
        candidate.layouts.insert(profile, at: 0)
        candidate.migrated = true
        if candidate.requested == nil { candidate.requested = LayoutSelection(id: profile.id, scene: profile.scene) }
        // Persist migration before ever writing a different layout to the device.
        try store.save(candidate)
        library = candidate
        if library.editingID == nil { await loadForEditing(profile, showEditor: false); _ = flushLayoutSave() }
    }
}
