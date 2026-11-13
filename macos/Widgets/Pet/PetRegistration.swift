import Foundation

extension WidgetRegistry {
    static let petPresets = [
        ComponentSizePreset(GridSize(columns: 14, rows: 8), name: "小号", frame: (512, 288)),
        ComponentSizePreset(GridSize(columns: 18, rows: 10), name: "大号", frame: (704, 400)),
    ]
    static let pet = WidgetDefinition(
        kind: .pet, wireID: 1,
        title: "Miucs 桌宠", symbol: "pawprint.fill", settingsTitle: "Miucs 桌宠", settingsSymbol: "pawprint",
        summary: "皮肤、键盘与声音", addTitle: "添加 Miucs 桌宠",
        defaults: [petPresets[0]], accepted: petPresets, selectable: petPresets,
        placement: .bottomCenter, minimumWidgetVersion: 0)
}
