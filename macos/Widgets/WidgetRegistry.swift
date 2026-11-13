import Foundation

/// Built-in component contract. Wire IDs and legacy sizes remain stable across releases.
struct WidgetDefinition: Sendable {
    enum Placement: Sendable { case topLeft, bottomLeft, bottomRight, bottomCenter, topCenter, firstFree }
    let kind: BuiltInPlugin
    let wireID: Int?
    let title: String
    let symbol: String
    let settingsTitle: String
    let settingsSymbol: String
    let summary: String
    let addTitle: String
    let defaults: [ComponentSizePreset]
    let accepted: [ComponentSizePreset]
    let selectable: [ComponentSizePreset]
    let placement: Placement
    var minimumWidgetVersion = 0
    var refresh: (@MainActor @Sendable (WidgetRuntime, Bool) -> Void)?
    var display: (@MainActor @Sendable (WidgetRuntime, ScreenLayout) async -> Void)?

    func recognizes(_ component: Component) -> Bool {
        if kind == .pictures {
            return Component.pictureIDs.contains(component.id) && acceptsSize(component)
        }
        guard component.id == wireID else { return false }
        // A malformed pet must still be treated as a pet so layout validation rejects it.
        return kind == .pet || acceptsSize(component)
    }

    private func acceptsSize(_ component: Component) -> Bool {
        accepted.contains { $0.contentWidth == component.width && $0.contentHeight == component.height }
    }

    func makeComponent(in layout: ScreenLayout) -> Component? {
        guard let wireID, let preset = defaults.first(where: { layout.grid.contains($0.footprint) }) else { return nil }
        let size = preset.footprint, grid = layout.grid
        let position: GridPosition
        switch placement {
        case .topLeft: position = GridPosition(column: 0, row: 0)
        case .bottomLeft: position = GridPosition(column: 0, row: grid.rows - size.rows)
        case .bottomRight: position = GridPosition(column: grid.columns - size.columns, row: grid.rows - size.rows)
        case .bottomCenter: position = GridPosition(column: (grid.columns - size.columns) / 2, row: grid.rows - size.rows)
        case .topCenter: position = GridPosition(column: (grid.columns - size.columns + 1) / 2, row: 0)
        case .firstFree:
            position = layout.firstFreePosition(for: size) ?? GridPosition(column: (grid.columns - size.columns) / 2,
                                                                         row: (grid.rows - size.rows) / 2)
        }
        var component = Component(id: wireID, x: 0, y: 0, width: preset.contentWidth, height: preset.contentHeight)
        component.place(at: position)
        return component
    }

    func makeComponent(in grid: GridSize) -> Component? {
        let panel = Panel(nativeWidth: grid.width, nativeHeight: grid.height, maxComponents: 10,
                          maxPixels: Panel.deskIsle.maxPixels, maxJPEG: Panel.deskIsle.maxJPEG)
        return makeComponent(in: ScreenLayout(panel: panel, direction: .portrait, components: []))
    }
}

enum WidgetRegistry {
    // Preserve the existing payload dispatch order; menu/settings order is independent.
    static let all: [WidgetDefinition] = [garmin, codex, bluetooth, macLoad, notifications, pet, pictures]
    private static let byID = Dictionary(uniqueKeysWithValues: all.compactMap { definition in
        definition.wireID.map { ($0, definition) }
    })
    static let menu: [BuiltInPlugin] = [.notifications, .codex, .garmin, .bluetooth, .macLoad, .pictures]
    static func definition(for kind: BuiltInPlugin) -> WidgetDefinition {
        // Every enum case is covered by a registration, checked in the compatibility tests.
        all.first { $0.kind == kind }!
    }
    static func definition(for component: Component) -> WidgetDefinition? {
        let candidate = byID[component.id] ?? (Component.pictureIDs.contains(component.id) ? pictures : nil)
        return candidate?.recognizes(component) == true ? candidate : nil
    }
}
