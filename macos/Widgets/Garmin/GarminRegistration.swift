import Foundation

extension GridSize {
    static let garmin = GridSize(columns: 10, rows: 8)
}

extension WidgetRegistry {
    static let garmin = WidgetDefinition(
        kind: .garmin, wireID: Component.garminID,
        title: "佳明健康", symbol: "waveform.path.ecg", settingsTitle: "佳明健康", settingsSymbol: "waveform.path.ecg",
        summary: "中国区账号与健康数据", addTitle: "添加佳明健康",
        defaults: [ComponentSizePreset(.garmin)], accepted: [ComponentSizePreset(.garmin)], selectable: [],
        placement: .bottomLeft, minimumWidgetVersion: 0,
        refresh: { runtime, force in runtime.refreshGarminIfNeeded(force: force) },
        display: { runtime, layout in await runtime.displayGarmin(in: layout) })
}
