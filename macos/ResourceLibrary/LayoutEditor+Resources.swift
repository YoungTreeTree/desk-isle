import AppKit
import UniformTypeIdentifiers

struct ResourcePickerRequest: Identifiable, Sendable {
    enum Purpose: Sendable { case wallpaper, picture, model, manage }
    let id = UUID()
    var purpose: Purpose
    var layoutID: UUID?
    var componentID: Int?

    var title: String {
        switch purpose {
        case .wallpaper: "选择壁纸"
        case .picture: componentID == nil ? "添加图片" : "更换图片"
        case .model: "选择 3D 模型"
        case .manage: "我的资源"
        }
    }
}

extension LayoutEditor {
    func manageResources() {
        guard !libraryBusy, !applying, !loadingLayout else { return }
        resourcePicker = ResourcePickerRequest(purpose: .manage, layoutID: library.editingID)
    }

    func currentResourceAsset(for request: ResourcePickerRequest) -> UUID? {
        switch request.purpose {
        case .wallpaper: draftWallpaperID
        case .picture: request.componentID.flatMap { draftPictureIDs[$0] }
        case .model: draftModelID
        case .manage: nil
        }
    }

    func resourceUsage(_ entry: SavedResource) -> [String] {
        func uses(_ scene: LayoutScene) -> Bool {
            !entry.assetIDs.isDisjoint(with: Array(scene.pictureIDs.values) + [scene.wallpaperID, scene.modelID].compactMap { $0 })
        }
        var names = library.layouts.filter { uses($0.scene) }.map(\.name)
        if let snapshot = library.requested, uses(snapshot.scene), !library.layouts.contains(where: { $0.id == snapshot.id && uses($0.scene) }) {
            names.append("待同步的小屏画面")
        }
        if let snapshot = library.displayed, uses(snapshot.scene), !library.layouts.contains(where: { $0.id == snapshot.id && uses($0.scene) }) {
            names.append("小屏当前画面")
        }
        return names
    }

    func protectedResourceIDs() throws -> Set<UUID> {
        let draftIDs = Array(editingScene.pictureIDs.values) + [editingScene.wallpaperID, editingScene.modelID].compactMap { $0 }
        return try libraryStore.referencedAssetIDs(in: library).union(draftIDs)
    }

    /// Import only adds to the collection. The picker remains open until the user chooses Use.
    func importResource(for request: ResourcePickerRequest, model: Bool) async -> UUID? {
        guard !resourceBusy, !applying else { return nil }
        resourceBusy = true
        defer { resourceBusy = false }
        let panel = NSOpenPanel()
        panel.title = model ? "导入 3D 模型" : "导入图片"
        panel.prompt = "导入"
        panel.allowedContentTypes = model ? [UTType(filenameExtension: "glb") ?? .data] : [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow { response = await panel.beginSheetModal(for: window) }
        else { response = await panel.begin() }
        guard response == .OK, let url = panel.url else { return nil }
        notice = model ? "正在准备模型…" : "正在保存图片…"
        do {
            let store = libraryStore
            let resourceID = try await Task.detached(priority: .userInitiated) {
                let assetID: UUID
                if model { assetID = try store.storeModel(Model3DFile(from: url)) }
                else {
                    let file = try PictureFile(from: url)
                    // Reject unsupported images before they appear as usable library items.
                    _ = try PictureAsset.prepare(file)
                    assetID = try store.storePicture(file)
                }
                return try store.resources.load().entries.first { $0.assetIDs.contains(assetID) }?.id
            }.value
            notice = "已保存到我的资源，选用后加入当前布局。"
            return resourceID
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    func useResource(_ resource: SavedResource, for request: ResourcePickerRequest) async {
        guard !resourceBusy, !applying, !loadingLayout else { return }
        resourceBusy = true
        defer { resourceBusy = false }
        notice = "正在准备资源…"
        do {
            try validateResourceTarget(request)
            let store = libraryStore
            switch request.purpose {
            case .wallpaper:
                let (id, wallpaper) = try await Task.detached(priority: .userInitiated) {
                    try store.resources.wallpaper(for: resource.id)
                }.value
                try validateResourceTarget(request)
                try store.resources.recordUse(of: id)
                draftWallpaperID = id
                selectWallpaper(wallpaper)
            case .picture:
                guard let id = resource.pictureID else { throw PictureError.unreadable }
                let (file, asset) = try await Task.detached(priority: .userInitiated) {
                    let file = try store.picture(id)
                    return (file, try PictureAsset.prepare(file))
                }.value
                try validateResourceTarget(request)
                try storePicture(file, asset: asset, replacing: request.componentID, storedID: id)
            case .model:
                guard let id = resource.modelID else { throw Model3DError.invalid("模型文件缺失，请重新导入。") }
                let file = try await Task.detached(priority: .userInitiated) { try store.model(id) }.value
                try validateResourceTarget(request)
                try importModel3D(file, storedID: id)
            case .manage: return
            }
            if flushLayoutSave() {
                resourcePicker = nil
                notice = "已保存到当前布局，点击「应用到小屏」生效。"
            } else { notice = libraryError ?? "布局保存失败，请重试。" }
        } catch { notice = error.localizedDescription }
    }

    private func validateResourceTarget(_ request: ResourcePickerRequest) throws {
        guard request.layoutID == library.editingID else { throw LayoutLibraryError.message("布局已切换，请关闭选择器后重试。") }
        if request.purpose == .picture {
            if let id = request.componentID {
                guard draft.components.contains(where: { $0.id == id && $0.isPicture }) else { throw PictureError.noRoom }
            } else if !canAddPicture { throw PictureError.noRoom }
        }
        if request.purpose == .model, draft.model3D == nil, !canAdd(.model3D) {
            throw Model3DError.invalid("当前布局放不下 3D 组件，请先腾出空间。")
        }
    }
}
