import XCTest
import Combine
@testable import DeskIsle

final class WidgetRegistryTests: XCTestCase {
    private struct LegacyCase: Decodable {
        let direction: Int
        let component: [Int]
        let action: String
        let wire: String
        let valid: Bool
        let name: String
        let symbol: String
        let presets: [String]
    }

    func testPreRefactorLayoutsKeepWireBytesSizesAndMigrationBehavior() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/layout-compatibility.json")
        let cases = try JSONDecoder().decode([LegacyCase].self, from: Data(contentsOf: url))
        XCTAssertEqual(cases.count, 290)
        for item in cases {
            let v = item.component
            let component = Component(id: v[0], x: v[1], y: v[2], width: v[3], height: v[4])
            var layout = ScreenLayout(panel: .deskIsle, direction: ScreenDirection(rawValue: item.direction)!, components: [component])
            let label = "\(item.direction) / \(v) / \(item.action)"
            XCTAssertEqual(component.name, item.name, label)
            XCTAssertEqual(component.symbol, item.symbol, label)
            XCTAssertEqual(component.sizePresets.map(\.label), item.presets, label)
            switch item.action {
            case "upgrade": layout = layout.upgradingCodexFootprint().upgradingNotificationFootprint().upgradingBluetoothFootprint()
            case "rotate": _ = layout.changeDirection(to: ScreenDirection(rawValue: (item.direction + 1) % 4)!)
            case "move": layout.move(component.id, to: GridPosition(column: 100, row: -2))
            case "resize": if let last = component.sizePresets.last { layout.resize(component.id, to: last.footprint) }
            default: break
            }
            XCTAssertEqual(layout.encoded().base64EncodedString(), item.wire, label)
            XCTAssertEqual(layout.isValid, item.valid, label)
        }
    }

    func testRegistryCoversSettingsAndKeepsDeviceIDsUnique() {
        XCTAssertEqual(Set(WidgetRegistry.all.map(\.kind)), Set(BuiltInPlugin.allCases))
        XCTAssertEqual(WidgetRegistry.all.count, BuiltInPlugin.allCases.count)
        let ids = WidgetRegistry.all.compactMap(\.wireID)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(Set(ids), [1, 0x8001, 0x8002, 0x8003, 0x8004, 0x8005])
        XCTAssertEqual(WidgetRegistry.all.filter { $0.refresh != nil }.map(\.kind), [.garmin, .codex, .bluetooth, .macLoad])
        XCTAssertEqual(WidgetRegistry.all.filter { $0.display != nil }.map(\.kind), [.garmin, .codex, .bluetooth, .macLoad])
    }

    func testDefaultPlacementInBothOrientationsAndUnknownComponents() throws {
        for direction in [ScreenDirection.portrait, .left] {
            let layout = ScreenLayout(panel: .deskIsle, direction: direction, components: [])
            for definition in WidgetRegistry.all where definition.wireID != nil {
                let component = try XCTUnwrap(definition.makeComponent(in: layout))
                XCTAssertTrue(component.fits(layout.grid))
                XCTAssertEqual(component.definition?.kind, definition.kind)
            }
            let pet = try XCTUnwrap(WidgetRegistry.pet.makeComponent(in: layout))
            XCTAssertEqual(pet.position.row + pet.footprint.rows, layout.grid.rows)
            let notification = try XCTUnwrap(WidgetRegistry.notifications.makeComponent(in: layout))
            XCTAssertEqual(notification.position.row, 0)
            XCTAssertEqual(notification.footprint, direction.isLandscape ? .notificationWide : .notificationCompact)
        }
        let unknown = Component(id: 0x9000, x: 0, y: 0, width: 240, height: 160)
        XCTAssertTrue(unknown.isPlaceholder)
        let badPet = Component(id: 1, x: 0, y: 0, width: 40, height: 40)
        XCTAssertTrue(badPet.isPet)
        XCTAssertFalse(ScreenLayout(panel: .deskIsle, direction: .portrait, components: [badPet]).isValidInPixels)
    }

    @MainActor
    func testRuntimeProfileChangesAndNotificationsDoNotEditLayout() throws {
        let domain = "deskisle.tests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        let settings = ConnectionSettings(preferences: preferences, inspectConnections: false)
        let runtime = WidgetRuntime(usb: LayoutUSB(), connections: settings)
        var draft = ScreenLayout.factory()
        draft.move(1, to: GridPosition(column: 2, row: 1))
        let context = WidgetContext(draft: draft, applied: .factory(), connected: false, applying: false, revision: 7)
        runtime.context = { context }
        runtime.nextCodexRead = .distantFuture
        runtime.nextGarminRead = 12345
        settings.updateCodex { $0.home = "/tmp/deskisle-test-codex" }
        XCTAssertEqual(runtime.nextCodexRead, .distantPast)
        settings.updateGarmin { $0.enabled = true }
        XCTAssertEqual(runtime.nextGarminRead, 0)
        runtime.testNotification()
        XCTAssertEqual(runtime.notificationSnapshot.item?.title, "通知已接通")
        XCTAssertFalse(runtime.notificationSending, "Disconnected devices must not send notifications")
        XCTAssertEqual(runtime.draft, draft)
        XCTAssertEqual(runtime.applied, .factory())
        runtime.stopNotifications()
        runtime.stopNotifications()
    }
    @MainActor
    func testEditorGatesCapabilitiesAndForwardsRuntimeChangesWithoutRetainCycle() throws {
        let domain = "deskisle.tests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        let usb = LayoutUSB()
        let settings = ConnectionSettings(preferences: preferences, inspectConnections: false)
        let pet = PetSettings(usb: usb, preferences: preferences, importLegacySettings: false)
        var editor: LayoutEditor? = LayoutEditor(usb: usb, displaySettings: DisplaySettings(usb: usb),
                                                connections: settings, petSettings: pet)
        weak var weakEditor = editor
        weak var weakRuntime = editor?.widgets
        weak var weakPictures = editor?.pictureRuntime
        XCTAssertFalse(editor!.canAdd(.pet))
        editor!.connected = true
        editor!.widgetVersion = 1
        XCTAssertFalse(editor!.canAdd(.macLoad))
        editor!.widgetVersion = 2
        XCTAssertTrue(editor!.canAdd(.macLoad))
        editor!.connected = false
        editor!.add(.notifications)
        XCTAssertFalse(editor!.canAdd(.notifications))
        XCTAssertTrue(editor!.hasChanges)
        XCTAssertEqual(editor!.applied, .factory(), "Adding must not apply a draft")
        let draft = editor!.draft
        var changes = 0
        let observation = editor!.objectWillChange.sink { changes += 1 }
        editor!.testNotification()
        XCTAssertGreaterThan(changes, 0, "The view must receive notification runtime changes")
        XCTAssertEqual(editor!.draft, draft)
        XCTAssertEqual(editor!.notificationSnapshot.item?.title, "通知已接通")
        editor!.importingPicture = true
        XCTAssertFalse(editor!.canAdd(.pictures))
        XCTAssertFalse(editor!.canApply)
        observation.cancel()
        editor = nil
        XCTAssertNil(weakEditor)
        XCTAssertNil(weakRuntime)
        XCTAssertNil(weakPictures)
    }

}
