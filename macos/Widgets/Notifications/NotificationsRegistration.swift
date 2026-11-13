import Foundation

extension GridSize {
    static let notificationCompact = GridSize(columns: 12, rows: 4)
    static let notificationWide = GridSize(columns: 23, rows: 7)
    static let notificationSizes = [notificationWide, notificationCompact]
}

extension WidgetRegistry {
    static let notifications = WidgetDefinition(
        kind: .notifications, wireID: Component.notificationsID,
        title: "通知岛", symbol: "bell.fill", settingsTitle: "通知岛", settingsSymbol: "bell.badge",
        summary: "Agent 事件与通知", addTitle: "添加通知岛",
        defaults: GridSize.notificationSizes.map { ComponentSizePreset($0) }, accepted: GridSize.notificationSizes.map { ComponentSizePreset($0) }, selectable: [],
        placement: .topCenter, minimumWidgetVersion: 0)
}
