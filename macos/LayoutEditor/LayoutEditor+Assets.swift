import AppKit
import UniformTypeIdentifiers


extension LayoutEditor {
    func choosePicture(replacing componentID: Int? = nil) {
        guard !applying, !libraryBusy, !loadingLayout, componentID != nil || canAddPicture else { return }
        resourcePicker = ResourcePickerRequest(purpose: .picture, layoutID: library.editingID, componentID: componentID)
    }

    func chooseWallpaper() {
        guard !applying, !libraryBusy, !loadingLayout else { return }
        resourcePicker = ResourcePickerRequest(purpose: .wallpaper, layoutID: library.editingID)
    }

    func restoreDefaultWallpaper() {
        guard !applying, !importingWallpaper, draftWallpaperID != nil else { return }
        draftWallpaperID = nil
        selectWallpaper(.bundled)
    }

    func selectWallpaper(_ selected: ScreenWallpaper) {
        wallpaper = selected
        wallpaperNotice = nil
        notice = ""
        recordDraftChange()
    }

    func storePicture(_ file: PictureFile, asset: PictureAsset, replacing componentID: Int?, storedID: UUID? = nil) throws {
        if let componentID {
            guard draft.components.contains(where: { $0.id == componentID && $0.isPicture }) else {
                throw PictureError.storageFailed
            }
            let resourceID = try storedID ?? libraryStore.storePicture(file)
            try libraryStore.resources.recordUse(of: resourceID)
            draftPictureIDs[componentID] = resourceID
            pictureRuntime.pictures[componentID] = asset
            pictureRuntime.pictureDisplayNotices.removeValue(forKey: componentID)
            recordDraftChange()
        } else {
            let occupied = Set((draft.components + applied.components).map(\.id))
            guard canAdd, draft.grid.contains(.defaultPicture),
                  let id = Component.pictureIDs.first(where: { !occupied.contains($0) }) else {
                throw PictureError.noRoom
            }
            let size = GridSize.defaultPicture
            let inset = draft.components.filter(\.isPicture).count % 4
            let position = draft.grid.clamped(GridPosition(column: inset, row: inset), for: size)
            var component = Component(id: id, x: 0, y: 0, width: size.width, height: size.height)
            component.place(at: position)
            let resourceID = try storedID ?? libraryStore.storePicture(file)
            try libraryStore.resources.recordUse(of: resourceID)
            draftPictureIDs[id] = resourceID
            pictureRuntime.pictures[id] = asset
            pictureRuntime.pictureDisplayNotices.removeValue(forKey: id)
            draft.components.append(component)
            selectedID = id
        }
    }

}
