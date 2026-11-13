import AppKit
import UniformTypeIdentifiers


extension LayoutEditor {
    func choosePicture(replacing componentID: Int? = nil) {
        guard !applying, !importingPicture, componentID != nil || canAddPicture else { return }
        let panel = NSOpenPanel()
        panel.title = componentID == nil ? "添加图片" : "更换图片"
        panel.prompt = "选取"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        importingPicture = true
        Task {
            defer { importingPicture = false }
            let response: NSApplication.ModalResponse
            if let window = NSApp.keyWindow {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = await panel.begin()
            }
            guard response == .OK, let url = panel.url else { return }
            notice = "正在准备图片…"
            do {
                let (file, asset) = try await Task.detached(priority: .userInitiated) {
                    let file = try PictureFile(from: url)
                    return (file, try PictureAsset.prepare(file))
                }.value
                try storePicture(file, asset: asset, replacing: componentID)
                notice = ""
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    func chooseWallpaper() {
        guard !applying, !importingWallpaper else { return }
        let panel = NSOpenPanel()
        panel.title = "更换桌屿壁纸"
        panel.prompt = "选取"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        importingWallpaper = true
        Task {
            defer { importingWallpaper = false }
            let response: NSApplication.ModalResponse
            if let window = NSApp.keyWindow {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = await panel.begin()
            }
            guard response == .OK, let url = panel.url else { return }
            do {
                let selected = try await Task.detached(priority: .userInitiated) {
                    try WallpaperStore.local().importImage(from: url)
                }.value
                selectWallpaper(selected)
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    func restoreDefaultWallpaper() {
        guard !applying, !importingWallpaper, wallpaper.isCustom else { return }
        importingWallpaper = true
        Task {
            defer { importingWallpaper = false }
            do {
                let selected = try await Task.detached(priority: .userInitiated) {
                    try WallpaperStore.local().restoreDefault()
                }.value
                selectWallpaper(selected)
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    func selectWallpaper(_ selected: ScreenWallpaper) {
        wallpaper = selected
        wallpaperNeedsSync = true
        wallpaperNotice = nil
        notice = ""
    }

    func syncWallpaper(for layout: ScreenLayout) async {
        guard let frame = wallpaper.frame(for: layout.direction) else {
            if wallpaperNotice == nil { wallpaperNotice = "找不到桌屿壁纸。" }
            return
        }
        let start = revision
        let expectUpload = wallpaper.isCustom || wallpaperNeedsSync
        let message: String?
        do {
            let supported = try await usb.showWallpaper(frame, for: layout.panel)
            message = supported || !expectUpload ? nil : "当前小屏固件不支持上传壁纸。"
        } catch {
            message = error.localizedDescription
        }
        guard start == revision, !Task.isCancelled, wallpaper.frame(for: layout.direction) === frame else { return }
        if message == nil, wallpaperNeedsSync {
            wallpaperNeedsSync = false
            wallpaperNotice = "壁纸已同步到小屏"
        } else if wallpaperNotice != message {
            wallpaperNotice = message
        }
    }

    func storePicture(_ file: PictureFile, asset: PictureAsset, replacing componentID: Int?) throws {
        if let componentID {
            guard draft.components.contains(where: { $0.id == componentID && $0.isPicture }) else {
                throw PictureError.storageFailed
            }
            try file.save(for: componentID)
            pictureRuntime.pictures[componentID] = asset
            pictureRuntime.pictureDisplayNotices.removeValue(forKey: componentID)
            pictureRuntime.updatePicturePlayback()
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
            try file.save(for: id)
            pictureRuntime.pictures[id] = asset
            pictureRuntime.pictureDisplayNotices.removeValue(forKey: id)
            draft.components.append(component)
            selectedID = id
        }
    }

}
