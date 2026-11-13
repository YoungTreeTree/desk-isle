import Foundation

extension GridSize {
    static let pictureSizes = [2, 4, 6, 8].map { GridSize(columns: $0, rows: $0) }
    static let defaultPicture = GridSize(columns: 4, rows: 4)
}

extension WidgetRegistry {
    static let pictures = WidgetDefinition(
        kind: .pictures, wireID: nil,
        title: "图片", symbol: "photo", settingsTitle: "图片与 GIF", settingsSymbol: "photo.on.rectangle",
        summary: "导入与画面布局", addTitle: "添加图片",
        defaults: [ComponentSizePreset(.defaultPicture)], accepted: GridSize.pictureSizes.map { ComponentSizePreset($0) }, selectable: GridSize.pictureSizes.map { ComponentSizePreset($0) },
        placement: .topLeft, minimumWidgetVersion: 0)
}
