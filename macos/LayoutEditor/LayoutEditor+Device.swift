import Foundation


extension LayoutEditor {
    func refresh() async {
        widgets.updateNotificationSnapshot()
        guard !applying else { return }
        defer {
            pictureRuntime.updatePicturePlayback()
            petSettings.update(connected: connected, hasComponent: applied.components.contains(where: \.isPet))
        }
        widgets.refreshSources()
        let start = revision
        do {
            let reply = try await usb.readLayout()
            guard start == revision, !Task.isCancelled else { return }
            await displaySettings.updateScreen(reply)
            guard start == revision, !Task.isCancelled else { return }
            if let reply {
                widgetVersion = reply.widgetVersion
                if !connected {
                    connected = true
                    if !notice.isEmpty { notice = "" }
                }
                let needsSave = reply.status == 3
                if unsaved != needsSave { unsaved = needsSave }
                if !hasChanges || draft.panel != reply.layout.panel {
                    var aligned = reply.layout.alignedToGrid()
                        .upgradingCodexFootprint().upgradingNotificationFootprint().upgradingBluetoothFootprint()
                    aligned.components.removeAll { $0.id == Component.retiredMusicID }
                    if draft != aligned { draft = aligned }
                }
                if applied != reply.layout { applied = reply.layout }
                await syncWallpaper(for: reply.layout)
                guard start == revision, !Task.isCancelled else { return }
                pictureRuntime.discardUnusedPictures()
                selectExistingComponent()
                widgets.refreshSources()
                pictureRuntime.loadPicturesIfNeeded()
                widgets.scheduleNotificationDisplay()
                await widgets.displayWidgets(in: reply.layout, while: { start == revision })
                if start == revision, !Task.isCancelled { await pictureRuntime.displayStillPictures(in: reply.layout) }
            } else if connected {
                connected = false
            }
        } catch {
            guard start == revision, !Task.isCancelled else { return }
            await displaySettings.updateScreen(nil)
            if connected { connected = false }
            let message = error.localizedDescription
            if notice != message { notice = message }
        }
    }

    func apply() async {
        guard canApply else { return }
        revision += 1
        applying = true
        notice = ""
        defer {
            applying = false
            petSettings.update(connected: connected, hasComponent: applied.components.contains(where: \.isPet))
            pictureRuntime.discardUnusedPictures()
            widgets.scheduleNotificationDisplay()
            pictureRuntime.updatePicturePlayback()
        }
        do {
            let reply = try await usb.apply(draft)
            await displaySettings.updateScreen(reply)
            widgetVersion = reply.widgetVersion
            applied = reply.layout
            unsaved = reply.status == 3
            switch reply.status {
            case 0:
                draft = reply.layout.alignedToGrid()
                notice = "已保存到小屏"
            case 1: notice = "小屏拒绝了这个布局，请检查组件尺寸和位置。"
            case 2: notice = "小屏暂时无法更新画面，可以重试。"
            default: notice = "小屏已显示新布局，保存失败，可以重试。"
            }
            if reply.status == 0 || reply.status == 3 {
                await syncWallpaper(for: reply.layout)
                widgets.refreshMacLoadIfNeeded()
                await widgets.displayWidgets(in: reply.layout, while: { true })
                await pictureRuntime.displayStillPictures(in: reply.layout)
            }
        } catch {
            await displaySettings.updateScreen(nil)
            connected = false
            notice = error.localizedDescription
        }
    }

}
