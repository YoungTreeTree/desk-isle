import Foundation
import Combine


@MainActor
final class LayoutEditor: ObservableObject {
    let connections: ConnectionSettings
    let petSettings: PetSettings
    @Published var draft = ScreenLayout.factory() { didSet { recordDraftChange() } }
    @Published var applied = ScreenLayout.factory()
    @Published var selectedID: Int? = 1
    @Published var connected = false
    @Published var applying = false
    @Published var unsaved = false
    @Published var notice = ""
    @Published var wallpaper = ScreenWallpaper.bundled
    @Published var importingWallpaper = false
    @Published var wallpaperNotice: String?
    @Published var importingPicture = false
    @Published var library = LayoutLibrary()
    @Published var showingLibrary = true
    @Published var libraryError: String?
    @Published var loadingLayout = false
    @Published var migratingLegacy = false
    @Published var syncPending = false
    let libraryStore: LayoutLibraryStore
    let device: any LayoutDevice
    var draftWallpaperID: UUID?
    var draftPictureIDs: [Int: UUID] = [:]
    var appliedWallpaper = ScreenWallpaper.bundled
    var restoringScene = false
    var libraryReadFailed = false
    var saveTask: Task<Void, Never>?
    var editGeneration = 0
    var editPreparation: Task<(ScreenWallpaper, [Int: PictureAsset], String), Never>?
    var scenePreparation: Task<PreparedLayoutScene, Error>?
    var preparedEditingScene: LayoutScene?
    var pendingPetSelection: LayoutSelection?
    var syncGeneration = 0
    var synchronization: Task<Void, Never>?
    var deviceReady = false
    var restoreRequested = true
    let usb: LayoutUSB
    let displaySettings: DisplaySettings
    let widgets: WidgetRuntime
    let pictureRuntime: PictureRuntime
    var revision = 0
    var widgetVersion = 0
    private var subscriptions: Set<AnyCancellable> = []

    init(usb: LayoutUSB, displaySettings: DisplaySettings, connections: ConnectionSettings = ConnectionSettings(),
         petSettings: PetSettings? = nil, libraryStore: LayoutLibraryStore = .local,
         device: (any LayoutDevice)? = nil) {
        self.libraryStore = libraryStore
        self.device = device ?? usb
        self.usb = usb
        self.displaySettings = displaySettings
        self.connections = connections
        self.petSettings = petSettings ?? PetSettings(usb: usb, importLegacySettings: connections.profile.setupComplete)
        widgets = WidgetRuntime(usb: usb, connections: connections)
        pictureRuntime = PictureRuntime(usb: usb)
        widgets.context = { [weak self] in self?.runtimeContext ?? .idle }
        pictureRuntime.context = { [weak self] in self?.runtimeContext ?? .idle }
        do {
            let loaded = try libraryStore.load()
            library = loaded.library
            if loaded.recovered { libraryError = "已从备份恢复布局库。" }
        } catch {
            libraryReadFailed = true
            libraryError = "无法读取布局库，原文件已保留：\(error.localizedDescription)"
        }
        self.petSettings.onSelectionChange = { [weak self] in self?.recordDraftChange() }
        self.petSettings.onReadinessChange = { [weak self] active in self?.completePendingPet(active: active) }
        self.petSettings.onStatusChange = { [weak self] status in
            guard let self, pendingPetSelection != nil, deviceReady else { return }
            notice = "桌宠同步中：\(status)"
        }
        if let profile = library.layouts.first(where: { $0.id == library.editingID }) ?? library.layouts.first {
            Task { [weak self] in await self?.loadForEditing(profile, showEditor: false) }
        }
        // Forward only actual state changes; do not introduce a preview refresh timer.
        for publisher in [widgets.objectWillChange, pictureRuntime.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
    }

    var runtimeContext: WidgetContext {
        WidgetContext(draft: draft, applied: applied, connected: connected, applying: applying || !deviceReady, revision: revision)
    }
    var selected: Component? { draft.components.first { $0.id == selectedID } }
    var hasChanges: Bool { library.displayed?.id != library.editingID || library.displayed?.scene != editingScene || draft != applied }
    var canAdd: Bool { draft.components.count < draft.panel.maxComponents }
    func canAdd(_ kind: BuiltInPlugin) -> Bool {
        let definition = WidgetRegistry.definition(for: kind)
        guard canAdd, !connected || widgetVersion >= definition.minimumWidgetVersion,
              definition.defaults.contains(where: { draft.grid.contains($0.footprint) }) else { return false }
        if kind == .pictures { return !importingPicture }
        return !draft.components.contains { $0.id == definition.wireID }
    }
    var canAddPicture: Bool { canAdd(.pictures) }
    var canApply: Bool { !applying && !importingPicture && !importingWallpaper && !loadingLayout && !libraryReadFailed && draft.isValid && (hasChanges || unsaved || syncPending) }

    func changeDirection(_ direction: ScreenDirection) {
        if draft.changeDirection(to: direction) {
            notice = ""
        } else {
            notice = "有组件在这个方向放不下，请先缩小它。"
        }
    }

    func move(_ id: Int, to position: GridPosition) {
        selectedID = id
        draft.move(id, to: position)
        notice = ""
    }

    func resize(_ component: Component, to footprint: GridSize) {
        draft.resize(component.id, to: footprint)
        notice = ""
    }

    func addPlaceholder() {
        guard canAdd, let id = (2..<Component.garminID).first(where: { id in !draft.components.contains { $0.id == id } }) else { return }
        let footprint = GridSize.defaultPlaceholder
        let inset = 1 + draft.components.count % 4
        let position = draft.grid.clamped(GridPosition(column: inset, row: inset), for: footprint)
        let component = Component(id: id, x: position.column * GridSize.cellPixels, y: position.row * GridSize.cellPixels,
                                  width: footprint.width, height: footprint.height)
        draft.components.append(component)
        selectedID = component.id
        notice = ""
    }

    func add(_ kind: BuiltInPlugin) {
        guard canAdd(kind) else { return }
        if kind == .pictures { choosePicture(); return }
        let definition = WidgetRegistry.definition(for: kind)
        guard let component = definition.makeComponent(in: draft) else { return }
        draft.components.append(component)
        selectedID = component.id
        notice = ""
        definition.refresh?(widgets, false)
    }

    func reorder(_ id: Int, by offset: Int) {
        guard let index = draft.components.firstIndex(where: { $0.id == id }),
              draft.components.indices.contains(index + offset) else { return }
        draft.components.swapAt(index, index + offset)
        notice = ""
    }

    func remove(_ id: Int) {
        draft.components.removeAll { $0.id == id }
        pictureRuntime.discardUnusedPictures()
        selectExistingComponent()
        notice = ""
    }

    func reset() {
        draft = .factory(panel: draft.panel)
        pictureRuntime.discardUnusedPictures()
        selectedID = 1
        notice = ""
    }

    func selectExistingComponent() {
        let firstID = draft.components.first?.id
        if selected == nil && selectedID != firstID { selectedID = firstID }
    }
}
