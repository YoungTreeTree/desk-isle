import Foundation
import IOKit.ps

struct BluetoothDevice: Equatable, Sendable {
    let name: String
    let symbol: String
    let battery: Int?
    let leftBattery: Int?
    let rightBattery: Int?
    let caseBattery: Int?

    var level: Int? {
        battery ?? [leftBattery, rightBattery].compactMap { $0 }.min() ?? caseBattery
    }

    var batteryDetails: String {
        [("左", leftBattery), ("右", rightBattery), ("盒", caseBattery)].compactMap { label, value in
            value.map { "\(label) \($0)%" }
        }.joined(separator: " · ")
    }
}

struct BluetoothCardContent: Equatable, Sendable {
    enum Accessories: Equatable, Sendable {
        case loading
        case off
        case unavailable
        case connected([BluetoothDevice])
    }

    static let loading = Self(computerBattery: nil, accessories: .loading)

    let computerBattery: Int?
    let accessories: Accessories
}

enum BluetoothSource {
    static let refreshSeconds = 30

    static func fetch() async -> BluetoothCardContent {
        await Task.detached(priority: .utility) {
            let data = run("/usr/sbin/system_profiler",
                           ["SPBluetoothDataType", "-json", "-detailLevel", "full", "-timeout", "5"])
            let accessories = data.map { parse($0, accessoryLevels: accessoryLevels) } ?? .unavailable
            return BluetoothCardContent(computerBattery: readComputerBattery(), accessories: accessories)
        }.value
    }

    static func parse(_ data: Data, accessoryLevels: () -> [String: Int] = { [:] }) -> BluetoothCardContent.Accessories {
        guard let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let bluetooth = (report["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let controller = bluetooth["controller_properties"] as? [String: Any] else { return .unavailable }
        if controller["controller_state"] as? String == "attrib_off" { return .off }

        let connected = bluetooth["device_connected"] as? [[String: [String: Any]]] ?? []
        var fallback: [String: Int]?
        var devices: [BluetoothDevice] = []
        for entry in connected {
            for (name, fields) in entry {
                let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let left = percent(fields["device_batteryLevelLeft"])
                let right = percent(fields["device_batteryLevelRight"])
                let box = percent(fields["device_batteryLevelCase"])
                var battery = percent(fields["device_batteryLevelMain"]) ?? percent(fields["device_batteryLevel"])
                if battery == nil, left == nil, right == nil, box == nil,
                   let address = address(fields["device_address"]) {
                    if fallback == nil { fallback = accessoryLevels() }
                    battery = fallback?[address]
                }
                let type = (fields["device_minorType"] as? String ?? "") + " " + label
                devices.append(BluetoothDevice(name: label.isEmpty ? "蓝牙设备" : label,
                                               symbol: symbol(for: type), battery: battery,
                                               leftBattery: left, rightBattery: right, caseBattery: box))
            }
        }
        return .connected(devices.sorted {
            if ($0.level != nil) != ($1.level != nil) { return $0.level != nil }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        })
    }

    private static func readComputerBattery() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let fields = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  fields[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  fields[kIOPSIsPresentKey] as? Bool == true,
                  let current = fields[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = fields[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0, (0...maximum).contains(current) else { continue }
            return Int((Double(current) / Double(maximum) * 100).rounded())
        }
        return nil
    }

    private static func accessoryLevels() -> [String: Int] {
        guard let data = run("/usr/sbin/ioreg", ["-a", "-r", "-d", "1", "-k", "BatteryPercent"]),
              let nodes = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
                as? [[String: Any]] else { return [:] }
        var levels: [String: Int] = [:]
        for node in nodes {
            if let address = address(node["DeviceAddress"]), let level = percent(node["BatteryPercent"]) {
                levels[address] = level
            }
        }
        return levels
    }

    private static func percent(_ value: Any?) -> Int? {
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "%")))
        guard let level = value as? Int ?? text.flatMap({ Int($0) }), (0...100).contains(level) else { return nil }
        return level
    }

    private static func address(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let normalized = text.lowercased().filter { $0 != ":" && $0 != "-" }
        guard normalized.utf8.count == 12,
              normalized.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return normalized
    }

    private static func symbol(for type: String) -> String {
        let name = type.lowercased()
        if name.contains("trackpad") || name.contains("触控板") { return "trackpad" }
        if name.contains("mouse") || name.contains("鼠标") { return "computermouse" }
        if name.contains("keyboard") || name.contains("键盘") { return "keyboard" }
        if name.contains("head") || name.contains("airpods") || name.contains("耳机") { return "headphones" }
        if name.contains("speaker") || name.contains("音箱") { return "hifispeaker" }
        if name.contains("phone") || name.contains("手机") { return "iphone" }
        if name.contains("computer") || name.contains("book") { return "laptopcomputer" }
        return "dot.radiowaves.left.and.right"
    }

    private static func run(_ path: String, _ arguments: [String]) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = try output.fileHandleForReading.readToEnd()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }
}
