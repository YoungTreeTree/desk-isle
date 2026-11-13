import Foundation

extension GridSize {
    static let macLoad = GridSize(columns: 8, rows: 4)
    static let macLoadLarge = GridSize(columns: 10, rows: 6)
}

extension WidgetRegistry {
    static let macLoadPresets = [ComponentSizePreset(.macLoad, name: "小号"),
                                ComponentSizePreset(.macLoadLarge, name: "大号")]
    static let macLoad = WidgetDefinition(
        kind: .macLoad, wireID: Component.macLoadID,
        title: "Mac 负载", symbol: "gauge.with.dots.needle.50percent", settingsTitle: "Mac 负载", settingsSymbol: "gauge.with.dots.needle.67percent",
        summary: "性能、温度与功耗", addTitle: "添加 Mac 负载",
        defaults: [ComponentSizePreset(.macLoad)], accepted: macLoadPresets, selectable: macLoadPresets,
        placement: .firstFree, minimumWidgetVersion: 2,
        refresh: { runtime, force in runtime.refreshMacLoadIfNeeded() },
        display: { runtime, layout in await runtime.displayMacLoad(in: layout) })
}
