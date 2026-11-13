import Foundation

extension GridSize {
    static let codex = GridSize(columns: 10, rows: 8)
    static let codexFootprints = [codex, GridSize(columns: 8, rows: 8), GridSize(columns: 8, rows: 10)]
}

extension WidgetRegistry {
    static let codex = WidgetDefinition(
        kind: .codex, wireID: Component.codexID,
        title: "Codex 用量", symbol: "terminal", settingsTitle: "Codex 用量", settingsSymbol: "terminal",
        summary: "订阅额度与 Token", addTitle: "添加 Codex 用量",
        defaults: [ComponentSizePreset(.codex)], accepted: GridSize.codexFootprints.map { ComponentSizePreset($0) }, selectable: [],
        placement: .bottomRight, minimumWidgetVersion: 0,
        refresh: { runtime, force in runtime.refreshCodexIfNeeded(force: force) },
        display: { runtime, layout in await runtime.displayCodex(in: layout) })
}
