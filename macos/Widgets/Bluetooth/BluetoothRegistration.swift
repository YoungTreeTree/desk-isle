import Foundation

extension GridSize {
    static let bluetooth = GridSize(columns: 8, rows: 4)
    static let previousBluetooth = GridSize(columns: 7, rows: 5)
    static let legacyBluetooth = GridSize(columns: 5, rows: 5)
    static let bluetoothFootprints = [bluetooth, previousBluetooth, legacyBluetooth]
}

extension WidgetRegistry {
    static let bluetooth = WidgetDefinition(
        kind: .bluetooth, wireID: Component.bluetoothID,
        title: "蓝牙设备", symbol: "dot.radiowaves.left.and.right", settingsTitle: "蓝牙电量", settingsSymbol: "battery.75percent",
        summary: "配件电量与刷新", addTitle: "添加蓝牙设备",
        defaults: [ComponentSizePreset(.bluetooth)], accepted: GridSize.bluetoothFootprints.map { ComponentSizePreset($0) }, selectable: [],
        placement: .topLeft, minimumWidgetVersion: 0,
        refresh: { runtime, force in runtime.refreshBluetoothIfNeeded() },
        display: { runtime, layout in await runtime.displayBluetooth(in: layout) })
}
