import Foundation

enum ScreenDirection: Int, CaseIterable, Identifiable, Sendable {
    case portrait, right, upsideDown, left
    var id: Int { rawValue }
    var isLandscape: Bool { rawValue % 2 == 1 }
    var title: String {
        switch self {
        case .portrait: "竖放"
        case .right: "向右横放"
        case .upsideDown: "倒置"
        case .left: "向左横放"
        }
    }
}

struct GridPosition: Equatable, Sendable {
    let column: Int
    let row: Int
}

struct GridSize: Hashable, Sendable {
    static let cellPixels = 40
    static let defaultPlaceholder = GridSize(columns: 6, rows: 4)
    static let placeholderSizes = [
        GridSize(columns: 2, rows: 3),
        GridSize(columns: 3, rows: 2),
        GridSize(columns: 4, rows: 6),
        defaultPlaceholder,
    ]

    let columns: Int
    let rows: Int

    var width: Int { columns * Self.cellPixels }
    var height: Int { rows * Self.cellPixels }
    var label: String { "\(columns) × \(rows) 格" }
    var notificationFootprint: GridSize? { Self.notificationSizes.first(where: contains) }

    func contains(_ footprint: GridSize) -> Bool {
        footprint.columns > 0 && footprint.rows > 0 &&
            footprint.columns <= columns && footprint.rows <= rows
    }

    func clamped(_ position: GridPosition, for footprint: GridSize) -> GridPosition {
        GridPosition(column: min(max(0, position.column), max(0, columns - footprint.columns)),
                     row: min(max(0, position.row), max(0, rows - footprint.rows)))
    }
}

struct ComponentSizePreset: Sendable {
    let footprint: GridSize
    let contentWidth: Int
    let contentHeight: Int
    let name: String?

    init(_ footprint: GridSize, name: String? = nil, frame: (width: Int, height: Int)? = nil) {
        self.footprint = footprint
        self.name = name
        contentWidth = frame?.width ?? footprint.width
        contentHeight = frame?.height ?? footprint.height
    }

    var label: String {
        if let name { return "\(name) · \(footprint.label)" }
        return footprint.label
    }
}

struct Component: Identifiable, Equatable, Sendable {
    static let garminID = 0x8001
    static let codexID = 0x8002
    static let notificationsID = 0x8003
    static let bluetoothID = 0x8004
    static let macLoadID = 0x8005
    static let retiredMusicID = 0x8006
    static let pictureIDs = 0x8100...0x81FF

    let id: Int
    // Pixel bounds of the rendered content, as sent over USB.
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var definition: WidgetDefinition? { WidgetRegistry.definition(for: self) }
    var isPet: Bool { id == 1 }
    var isGarmin: Bool { definition?.kind == .garmin }
    var isCodex: Bool { definition?.kind == .codex }
    var isNotifications: Bool { definition?.kind == .notifications }
    var isBluetooth: Bool { definition?.kind == .bluetooth }
    var isMacLoad: Bool { definition?.kind == .macLoad }
    var isPicture: Bool { definition?.kind == .pictures }
    var isPlaceholder: Bool { definition == nil }
    var sizePresets: [ComponentSizePreset] {
        definition?.selectable ?? GridSize.placeholderSizes.map { ComponentSizePreset($0) }
    }
    fileprivate var petPreset: ComponentSizePreset? {
        guard isPet else { return nil }
        return WidgetRegistry.pet.accepted.first { width == $0.contentWidth && height == $0.contentHeight }
    }
    var name: String { definition?.title ?? "自定义组件 \(id - 1)" }
    var symbol: String { definition?.symbol ?? "square.dashed" }
    var footprint: GridSize {
        petPreset?.footprint ?? GridSize(columns: width / GridSize.cellPixels, rows: height / GridSize.cellPixels)
    }
    var insetX: Int { petPreset.map { ($0.footprint.width - $0.contentWidth) / 2 } ?? 0 }
    var insetY: Int { petPreset.map { ($0.footprint.height - $0.contentHeight) / 2 } ?? 0 }
    var position: GridPosition {
        GridPosition(column: (x - insetX) / GridSize.cellPixels, row: (y - insetY) / GridSize.cellPixels)
    }
    var jpegWidth: Int { (width + 15) & ~15 }
    var jpegHeight: Int { (height + 15) & ~15 }
    var jpegPixels: Int { jpegWidth * jpegHeight }

    func fits(_ grid: GridSize) -> Bool {
        let cell = GridSize.cellPixels
        return grid.contains(footprint) && x >= insetX && y >= insetY &&
            (x - insetX) % cell == 0 && (y - insetY) % cell == 0 &&
            (isPet || (width % cell == 0 && height % cell == 0)) &&
            position == grid.clamped(position, for: footprint)
    }

    mutating func place(at position: GridPosition) {
        x = position.column * GridSize.cellPixels + insetX
        y = position.row * GridSize.cellPixels + insetY
    }

    static func pet(in grid: GridSize) -> Component? { WidgetRegistry.pet.makeComponent(in: grid) }
    static func garmin(in grid: GridSize) -> Component? { WidgetRegistry.garmin.makeComponent(in: grid) }
    static func codex(in grid: GridSize) -> Component? { WidgetRegistry.codex.makeComponent(in: grid) }
    static func notifications(in grid: GridSize) -> Component? { WidgetRegistry.notifications.makeComponent(in: grid) }
    static func bluetooth(in grid: GridSize) -> Component? { WidgetRegistry.bluetooth.makeComponent(in: grid) }

}

struct Panel: Equatable, Sendable {
    let nativeWidth: Int
    let nativeHeight: Int
    let maxComponents: Int
    let maxPixels: Int
    let maxJPEG: Int

    static let deskIsle = Panel(nativeWidth: 720, nativeHeight: 1280, maxComponents: 10,
                                maxPixels: 1_843_200, maxJPEG: 98_304)
}

struct ScreenLayout: Equatable, Sendable {
    let panel: Panel
    var direction: ScreenDirection
    var components: [Component]

    static func factory(panel: Panel = .deskIsle) -> ScreenLayout {
        var layout = ScreenLayout(panel: panel, direction: .portrait, components: [])
        if let pet = Component.pet(in: layout.grid) { layout.components.append(pet) }
        return layout
    }

    var width: Int { direction.isLandscape ? panel.nativeHeight : panel.nativeWidth }
    var height: Int { direction.isLandscape ? panel.nativeWidth : panel.nativeHeight }
    var grid: GridSize { GridSize(columns: width / GridSize.cellPixels, rows: height / GridSize.cellPixels) }
    var garmin: Component? { components.first(where: \.isGarmin) }
    var codex: Component? { components.first(where: \.isCodex) }
    var notifications: Component? { components.first(where: \.isNotifications) }
    var bluetooth: Component? { components.first(where: \.isBluetooth) }
    var macLoad: Component? { components.first(where: \.isMacLoad) }

    func firstFreePosition(for size: GridSize) -> GridPosition? {
        guard grid.contains(size) else { return nil }
        for row in 0...(grid.rows - size.rows) {
            for column in 0...(grid.columns - size.columns) {
                let overlaps = components.contains { component in
                    let origin = component.position
                    let footprint = component.footprint
                    return column < origin.column + footprint.columns && origin.column < column + size.columns &&
                        row < origin.row + footprint.rows && origin.row < row + size.rows
                }
                if !overlaps { return GridPosition(column: column, row: row) }
            }
        }
        return nil
    }

    var isValid: Bool {
        isValidInPixels && components.allSatisfy { $0.fits(grid) }
    }

    var isValidInPixels: Bool {
        guard components.count <= panel.maxComponents, Set(components.map(\.id)).count == components.count else { return false }
        var pixels = 0
        for component in components {
            guard (1...Int(UInt16.max)).contains(component.id), component.x >= 0, component.y >= 0,
                  (1...width).contains(component.width), (1...height).contains(component.height),
                  component.x <= width - component.width, component.y <= height - component.height else { return false }
            if component.isPet && component.petPreset == nil { return false }
            pixels += component.jpegPixels
        }
        return pixels <= panel.maxPixels
    }

    mutating func move(_ id: Int, to position: GridPosition) {
        guard let index = components.firstIndex(where: { $0.id == id }) else { return }
        let clamped = grid.clamped(position, for: components[index].footprint)
        components[index].place(at: clamped)
    }

    mutating func resize(_ id: Int, to footprint: GridSize) {
        guard grid.contains(footprint), let index = components.firstIndex(where: { $0.id == id }),
              let preset = components[index].sizePresets.first(where: { $0.footprint == footprint }) else { return }
        var component = components[index]
        var position = component.position
        if component.isPet {
            let size = component.footprint
            position = GridPosition(column: position.column + (size.columns - footprint.columns) / 2,
                                    row: position.row + size.rows - footprint.rows)
        }
        component.width = preset.contentWidth
        component.height = preset.contentHeight
        component.place(at: grid.clamped(position, for: footprint))
        components[index] = component
    }

    func upgradingCodexFootprint() -> ScreenLayout {
        guard grid.contains(.codex),
              let index = components.firstIndex(where: { $0.isCodex && $0.footprint != .codex }) else { return self }
        let component = components[index]
        let size = component.footprint
        let position = GridPosition(column: component.position.column + size.columns - GridSize.codex.columns,
                                    row: component.position.row + size.rows - GridSize.codex.rows)
        var updated = self
        updated.components[index].width = GridSize.codex.width
        updated.components[index].height = GridSize.codex.height
        updated.move(component.id, to: position)
        return updated.isValid ? updated : self
    }

    func upgradingNotificationFootprint() -> ScreenLayout {
        guard let size = grid.notificationFootprint,
              let index = components.firstIndex(where: { $0.isNotifications && $0.footprint != size }) else { return self }
        let component = components[index]
        let offset = Int((Double(component.footprint.columns - size.columns) / 2).rounded(.up))
        let position = GridPosition(column: component.position.column + offset, row: component.position.row)
        var updated = self
        updated.components[index].width = size.width
        updated.components[index].height = size.height
        updated.move(component.id, to: position)
        return updated.isValid ? updated : self
    }

    func upgradingBluetoothFootprint() -> ScreenLayout {
        guard grid.contains(.bluetooth),
              let index = components.firstIndex(where: { $0.isBluetooth && $0.footprint != .bluetooth }) else {
            return self
        }
        let component = components[index]
        var updated = self
        updated.components[index].width = GridSize.bluetooth.width
        updated.components[index].height = GridSize.bluetooth.height
        updated.move(component.id, to: component.position)
        return updated.isValid ? updated : self
    }

    mutating func changeDirection(to next: ScreenDirection) -> Bool {
        let oldGrid = grid
        var updated = self
        updated.direction = next
        let newGrid = updated.grid
        for index in components.indices {
            let component = components[index]
            let previousSize = component.footprint
            let size = component.isNotifications ? newGrid.notificationFootprint ?? previousSize : previousSize
            guard newGrid.contains(size) else { return false }
            let columnRoom = oldGrid.columns - previousSize.columns
            let columnFraction = (component.isPet || component.isNotifications) && columnRoom == 0
                ? 0.5 : Double(component.position.column) / Double(max(1, columnRoom))
            let rowFraction = Double(component.position.row) / Double(max(1, oldGrid.rows - previousSize.rows))
            let position = GridPosition(column: Int((columnFraction * Double(newGrid.columns - size.columns)).rounded()),
                                        row: Int((rowFraction * Double(newGrid.rows - size.rows)).rounded()))
            if size != previousSize {
                updated.components[index].width = size.width
                updated.components[index].height = size.height
            }
            updated.components[index].place(at: newGrid.clamped(position, for: size))
        }
        guard updated.isValid else { return false }
        self = updated
        return true
    }

    func alignedToGrid() -> ScreenLayout {
        if isValid { return self }
        let cell = GridSize.cellPixels
        let grid = grid
        var aligned = self
        for index in aligned.components.indices where aligned.components[index].isPlaceholder {
            let component = aligned.components[index]
            let columns = min(grid.columns, max(1, (component.width + cell / 2) / cell))
            let rows = min(grid.rows, max(1, (component.height + cell / 2) / cell))
            aligned.components[index].width = columns * cell
            aligned.components[index].height = rows * cell
        }
        var pixels = aligned.components.reduce(0) { $0 + $1.jpegPixels }
        while pixels > panel.maxPixels {
            let candidates = aligned.components.indices.filter { index in
                let component = aligned.components[index]
                return component.isPlaceholder && (component.width > cell || component.height > cell)
            }
            guard let index = candidates.max(by: { aligned.components[$0].jpegPixels < aligned.components[$1].jpegPixels })
            else { break }
            let component = aligned.components[index]
            if component.width >= component.height {
                aligned.components[index].width -= cell
            } else {
                aligned.components[index].height -= cell
            }
            pixels -= component.jpegPixels - aligned.components[index].jpegPixels
        }
        for index in aligned.components.indices {
            let original = components[index]
            let size = aligned.components[index].footprint
            let column = max(0, 2 * original.x + original.width - size.width + cell) / (2 * cell)
            let row = max(0, 2 * original.y + original.height - size.height + cell) / (2 * cell)
            aligned.components[index].place(at: grid.clamped(GridPosition(column: column, row: row), for: size))
        }
        return aligned
    }

    func encoded() -> Data {
        var bytes = Data([UInt8(direction.rawValue), UInt8(components.count)])
        for component in components {
            for value in [component.id, component.x, component.y, component.width, component.height] {
                withUnsafeBytes(of: UInt16(value).littleEndian) { bytes.append(contentsOf: $0) }
            }
        }
        return bytes
    }
}

struct ScreenBacklight: Equatable, Sendable {
    let brightness: Int
    let blanked: Bool

    init(brightness: Int, blanked: Bool) {
        self.brightness = brightness
        self.blanked = blanked
    }

    init?(line: String, sequence: UInt32) {
        let fields = line.split(separator: " ")
        guard fields.count == 5, fields[0] == "DESKISLE_BACKLIGHT", fields[1] == "1",
              UInt32(fields[2]) == sequence, let brightness = Int(fields[3]), (0...100).contains(brightness),
              fields[4] == "0" || fields[4] == "1" else { return nil }
        self.init(brightness: brightness, blanked: fields[4] == "1")
    }
}

struct LayoutReply: Sendable {
    let status: Int
    let layout: ScreenLayout
    let backlight: ScreenBacklight?
    let widgetVersion: Int

    init?(line: String, sequence: UInt32, backlight: ScreenBacklight? = nil, widgetVersion: Int = 0) {
        let fields = line.split(separator: " ")
        guard fields.count >= 11, fields[0] == "DESKISLE_LAYOUT", fields[1] == "1",
              UInt32(fields[2]) == sequence else { return nil }
        let values = fields.dropFirst(3).compactMap { Int($0) }
        guard values.count == fields.count - 3, (0...3).contains(values[0]),
              (512...4096).contains(values[1]), (512...4096).contains(values[2]),
              (1...64).contains(values[3]), values[4] > 0, values[5] > 0,
              let direction = ScreenDirection(rawValue: values[6]), (0...values[3]).contains(values[7]),
              values.count == 8 + 5 * values[7] else { return nil }

        let panel = Panel(nativeWidth: values[1], nativeHeight: values[2], maxComponents: values[3],
                          maxPixels: values[4], maxJPEG: values[5])
        let components = stride(from: 8, to: values.count, by: 5).map { i in
            Component(id: values[i], x: values[i + 1], y: values[i + 2], width: values[i + 3], height: values[i + 4])
        }
        let layout = ScreenLayout(panel: panel, direction: direction, components: components)
        guard layout.isValidInPixels else { return nil }
        self.status = values[0]
        self.layout = layout
        self.backlight = backlight
        self.widgetVersion = widgetVersion
    }
}
