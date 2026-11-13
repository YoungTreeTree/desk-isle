import Combine
import Foundation

enum BuiltInPlugin: String, CaseIterable, Identifiable {
    case garmin, codex, notifications, pet, macLoad, bluetooth, pictures, model3D
    var id: Self { self }
    var title: String { WidgetRegistry.definition(for: self).settingsTitle }
    var symbol: String { WidgetRegistry.definition(for: self).settingsSymbol }
    var summary: String { WidgetRegistry.definition(for: self).summary }

}

@MainActor
final class LocalPluginSettings: ObservableObject {
    @Published private(set) var macInterval: Int
    @Published private(set) var bluetoothInterval: Int
    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let mac = preferences.integer(forKey: "plugins.mac.interval")
        let bluetooth = preferences.integer(forKey: "plugins.bluetooth.interval")
        macInterval = [4, 8, 16].contains(mac) ? mac : 4
        bluetoothInterval = [30, 60, 120].contains(bluetooth) ? bluetooth : 30
    }
    func setMacInterval(_ value: Int) {
        guard [4, 8, 16].contains(value) else { return }
        macInterval = value; preferences.set(value, forKey: "plugins.mac.interval")
    }
    func setBluetoothInterval(_ value: Int) {
        guard [30, 60, 120].contains(value) else { return }
        bluetoothInterval = value; preferences.set(value, forKey: "plugins.bluetooth.interval")
    }
}
