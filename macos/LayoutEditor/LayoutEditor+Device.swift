import Foundation

extension LayoutEditor {
    func refresh() async {
        widgets.updateNotificationSnapshot()
        guard !applying else { return }
        defer {
            pictureRuntime.updatePicturePlayback()
            petSettings.update(connected: connected && deviceReady, hasComponent: deviceReady && applied.components.contains(where: \.isPet))
        }
        widgets.refreshSources()
        let start = revision
        do {
            let reply = try await device.readLayout()
            guard start == revision, !Task.isCancelled else { return }
            await displaySettings.updateScreen(reply)
            guard start == revision, !Task.isCancelled else { return }
            guard let reply else {
                connected = false
                deviceReady = false
                return
            }
            let reconnected = !connected
            connected = true
            widgetVersion = reply.widgetVersion
            unsaved = reply.status == 3
            try await migrateLegacyLayout(reply.layout)
            guard start == revision, !Task.isCancelled, !libraryReadFailed else { return }
            let deviceChanged = applied != reply.layout || (deviceReady && reply.layout.model3D != nil && !reply.modelResident)
            applied = reply.layout
            if reconnected || deviceChanged || restoreRequested {
                restoreRequested = false
                deviceReady = false
                if library.requested != nil {
                    syncPending = true
                    await synchronizeRequestedScene()
                }
                return
            }
            guard deviceReady else { return }
            try await syncWallpaper(appliedWallpaper, for: reply.layout)
            guard start == revision, !Task.isCancelled else { return }
            widgets.scheduleNotificationDisplay()
            await widgets.displayWidgets(in: reply.layout, while: { start == revision && !applying })
            if start == revision, !Task.isCancelled, !applying {
                await pictureRuntime.displayStillPictures(in: reply.layout)
            }
        } catch {
            guard start == revision, !Task.isCancelled else { return }
            notice = error.localizedDescription
            // A migration/storage error must not be mistaken for a transport disconnect.
            if !library.migrated { libraryError = "尚未完成原布局备份：\(error.localizedDescription)" }
            else {
                await displaySettings.updateScreen(nil)
                connected = false
                deviceReady = false
            }
        }
    }

    func apply() async {
        guard canApply else { return }
        recordDraftChange()
        guard let id = library.editingID else { return }
        await requestScene(LayoutSelection(id: id, scene: editingScene))
    }

    func requestScene(_ selection: LayoutSelection) async {
        guard !libraryReadFailed else { return }
        let previous = library.requested
        library.requested = selection
        guard flushLayoutSave() else { library.requested = previous; return }
        // The previous request may have changed device resources while still waiting
        // for its pet skin. A historical displayed snapshot cannot prove that a
        // newly selected scene is still on the board, even with identical geometry.
        if previous != selection { deviceReady = false }
        pendingPetSelection = nil
        scenePreparation?.cancel()
        syncGeneration += 1
        revision += 1
        syncPending = true
        if !connected {
            notice = "已保存到 Mac，连接小屏后切换"
            return
        }
        await synchronizeRequestedScene()
    }

    func synchronizeRequestedScene() async {
        guard connected, library.migrated, !libraryReadFailed else { return }
        if let synchronization { await synchronization.value; return }
        synchronization = Task { [weak self] in await self?.runSceneSynchronization() }
        await synchronization?.value
        synchronization = nil
    }

    private func runSceneSynchronization() async {
        applying = true
        defer {
            scenePreparation = nil
            applying = false
            petSettings.update(connected: connected && deviceReady, hasComponent: deviceReady && applied.components.contains(where: \.isPet))
            widgets.scheduleNotificationDisplay()
            pictureRuntime.updatePicturePlayback()
        }
        var attemptedGeneration = -1
        var transportRetries = 0
        while let selection = library.requested, connected, !Task.isCancelled {
            let generation = syncGeneration
            if attemptedGeneration != generation { attemptedGeneration = generation; transportRetries = 0 }
            let store = libraryStore
            do {
                try store.validateReferences(selection.scene)
                let petReady = !selection.scene.layout.components.contains(where: \.isPet) || !petSettings.enabled ||
                    (petSettings.nativeActive && petSettings.activeSkinID == selection.scene.skinID)
                if deviceReady, applied == selection.scene.layout,
                   library.displayed?.scene == selection.scene, !unsaved, petReady {
                    library.displayed = selection
                    syncPending = false
                    notice = "已应用到小屏"
                    _ = flushLayoutSave()
                    return
                }
                guard selection.scene.layout.isValid else { throw LayoutLibraryError.message("布局尺寸无效。") }
                if selection.scene.layout.components.contains(where: \.isPet),
                   !petSettings.skins.contains(where: { $0.id == selection.scene.skinID }) {
                    throw LayoutLibraryError.message("桌宠皮肤不可用，请重新选择皮肤。")
                }
                for component in selection.scene.layout.components {
                    if let definition = component.definition, widgetVersion < definition.minimumWidgetVersion {
                        throw LayoutLibraryError.message("当前固件不支持\(component.name)，请更新固件。")
                    }
                }
                let prepared: PreparedLayoutScene
                if selection.scene.layout.model3D == nil, !loadingLayout, let cached = preparedEditingScene,
                   cached.wallpaperID == selection.scene.wallpaperID,
                   cached.pictureIDs == selection.scene.pictureIDs,
                   editingScene.wallpaperID == cached.wallpaperID,
                   editingScene.pictureIDs == cached.pictureIDs {
                    prepared = PreparedLayoutScene(wallpaper: wallpaper, pictures: pictureRuntime.pictures)
                } else {
                    let task = Task.detached(priority: .userInitiated) { try store.prepare(selection.scene) }
                    scenePreparation = task
                    prepared = try await task.value
                    scenePreparation = nil
                }
                guard !Task.isCancelled else { return }
                if generation != syncGeneration { continue }
                guard prepared.wallpaper.frame(for: selection.scene.layout.direction) != nil else {
                    throw LayoutLibraryError.message("壁纸资源不可用，请更换壁纸。")
                }
                // Drain ongoing picture sends before changing the device's component geometry.
                await pictureRuntime.pausePlayback()
                if generation != syncGeneration { continue }
                deviceReady = false
                await petSettings.pauseForLayoutChange(skinID: selection.scene.skinID,
                    hasPet: selection.scene.layout.components.contains(where: \.isPet))
                if generation != syncGeneration { continue }
                let reply = try await device.apply(selection.scene.layout)
                applied = reply.layout
                widgetVersion = reply.widgetVersion
                unsaved = reply.status == 3
                guard reply.status == 0 || reply.status == 3 else {
                    throw LayoutLibraryError.message(reply.status == 1 ? "小屏拒绝了布局，请检查尺寸。" : "小屏暂时无法更新画面。")
                }
                if generation != syncGeneration { continue }
                appliedWallpaper = prepared.wallpaper
                pictureRuntime.appliedPictures = prepared.pictures
                if editingScene == selection.scene, !loadingLayout {
                    wallpaper = prepared.wallpaper
                    pictureRuntime.pictures = prepared.pictures
                    preparedEditingScene = selection.scene
                }
                try await syncWallpaper(prepared.wallpaper, for: reply.layout)
                if generation != syncGeneration { continue }
                await widgets.displayWidgets(in: reply.layout, while: { generation == syncGeneration })
                if generation != syncGeneration { continue }
                await pictureRuntime.displayAllPictures(in: reply.layout)
                if generation != syncGeneration { continue }
                if let model=prepared.model {
                    modelStats=nil
                    notice="正在上传 3D 模型…"
                    try await device.showModel3D(model.pack,scale:selection.scene.modelScale ?? 1)
                    if generation != syncGeneration { continue }
                }
                if !pictureRuntime.pictureDisplayNotices.isEmpty {
                    throw LayoutLibraryError.message("图片尚未完全同步，请重试。")
                }
                if let error = widgets.displayError(in: reply.layout) { throw LayoutLibraryError.message(error) }
                deviceReady = true
                pendingPetSelection = selection
                notice = "正在同步桌宠皮肤…"
                petSettings.activateSkin(selection.scene.skinID)
                petSettings.update(connected: true, hasComponent: applied.components.contains(where: \.isPet))
                completePendingPet(active: petSettings.nativeActive)
            } catch {
                if generation != syncGeneration { continue }
                syncPending = true
                if error is LayoutUSBError, transportRetries < 2, !Task.isCancelled {
                    transportRetries += 1
                    notice = "连接中断，正在重新同步（\(transportRetries)/2）…"
                    // Allow the old CH343 relay to release its exclusive port lock.
                    try? await Task.sleep(for: .milliseconds(300))
                    if let reply = try? await device.readLayout() {
                        applied = reply.layout
                        widgetVersion = reply.widgetVersion
                        continue
                    }
                    connected = false
                }
                notice = "未完全同步：\(error.localizedDescription)"
            }
            if generation == syncGeneration { return }
        }
    }

    func completePendingPet(active: Bool) {
        guard let selection = pendingPetSelection, selection == library.requested, deviceReady else { return }
        let hasPet = selection.scene.layout.components.contains(where: \.isPet)
        guard !hasPet || !petSettings.enabled || (active && petSettings.activeSkinID == selection.scene.skinID) else { return }
        pendingPetSelection = nil
        library.displayed = selection
        syncPending = unsaved
        notice = unsaved ? "小屏已显示新布局，但设备保存失败，请重试。" : "已应用到小屏"
        _ = flushLayoutSave()
    }

    func syncWallpaper(_ wallpaper: ScreenWallpaper, for layout: ScreenLayout) async throws {
        guard let frame = wallpaper.frame(for: layout.direction) else {
            throw LayoutLibraryError.message("找不到桌屿壁纸。")
        }
        guard try await device.showWallpaper(frame, for: layout.panel) else {
            throw LayoutLibraryError.message("当前小屏固件不支持上传壁纸。")
        }
    }
}
