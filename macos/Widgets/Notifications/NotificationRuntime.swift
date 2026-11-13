import Foundation


extension WidgetRuntime {
    func startNotifications() {
        do {
            notificationListener = try NotificationSocket.listen { [weak self] event in
                guard let self else { return }
                DispatchQueue.main.async { self.receiveNotification(event) }
            }
            notificationListenError = nil
        } catch {
            notificationListenError = error.localizedDescription
        }
    }

    func stopNotifications() {
        notificationListener?.cancel()
        notificationListener = nil
    }

    func testNotification() {
        receiveNotification(NotificationEvent(type: .post, source: "deskisle", title: "通知已接通",
                                              body: "这条通知会在几秒后收起", level: .success))
    }

    var codexSessionURL: URL? {
        guard let item = notificationSnapshot.item, item.source == "codex", let id = item.sessionID,
              UUID(uuidString: id) != nil else { return nil }
        return URL(string: "codex://threads/\(id)")
    }

    func receiveNotification(_ event: NotificationEvent) {
        notificationFeed.receive(event)
        updateNotificationSnapshot()
    }

    func updateNotificationSnapshot() {
        let snapshot = notificationFeed.snapshot()
        guard snapshot != notificationSnapshot else { return }
        notificationMotion.update(to: snapshot, at: ProcessInfo.processInfo.systemUptime)
        scheduleNotificationDisplay()
    }

    func scheduleNotificationDisplay() {
        guard connected, !applying, applied.notifications != nil else { return }
        notificationNeedsDisplay = true
        guard !notificationSending else { return }
        notificationSending = true
        Task {
            defer { notificationSending = false }
            while notificationNeedsDisplay {
                notificationNeedsDisplay = false
                guard connected, !applying else { break }
                let snapshot = notificationSnapshot
                var feed = notificationFeed
                let after = snapshot.expiresAt.map {
                    WidgetData.Notice(feed.snapshot(now: $0, includeBanners: false))
                }
                await sendWidget(WidgetData.Notice(snapshot), to: applied.notifications,
                                 notice: \.notificationDisplayNotice, expiresAt: snapshot.expiresAt, after: after)
            }
        }
    }

}
