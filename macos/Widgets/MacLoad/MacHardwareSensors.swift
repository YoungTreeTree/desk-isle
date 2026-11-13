#if canImport(DeskIsleNative)
import DeskIsleNative
#endif
import Foundation
import IOKit

// Owned by MacLoadSource's actor. One connection and a bounded metadata cache;
// no subprocesses, polling timer, or writes to the SMC.
final class MacHardwareSensors {
    private var connection: io_connect_t = 0
    private var descriptors: [String: desk_smc_key] = [:]
    private var described: Set<String> = []
    private let temperatureKeys: [String]

    init() {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        let result = sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        let chip = result == 0 ? String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        // M4 CPU core keys, documented by Stats (Modules/Sensors/values.swift).
        // Other chips need their own mapping; PMU/proximity readings are not CPU cores.
        temperatureKeys = chip == "Apple M4" || chip == "Apple M4 Pro" || chip == "Apple M4 Max"
            ? ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"] : []
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func sample() -> (cpuTemperature: Int?, systemPowerTenths: Int?) {
        if connection == 0 {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
            guard service != 0 else { return (nil, nil) }
            defer { IOObjectRelease(service) }
            guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
                connection = 0
                return (nil, nil)
            }
        }
        let temperatures = temperatureKeys.compactMap { read($0, in: 1...150) }
        let power = read("PSTR", in: 0...2000)
        if temperatures.isEmpty && power == nil {
            // Sleep/reconnect can invalidate a user client. Retry on the next regular sample.
            IOServiceClose(connection)
            connection = 0
            descriptors.removeAll(keepingCapacity: true)
            described.removeAll(keepingCapacity: true)
        }
        return (temperatures.max().map { Int($0.rounded()) }, power.map { Int(($0 * 10).rounded()) })
    }

    private func read(_ key: String, in range: ClosedRange<Double>) -> Double? {
        if described.insert(key).inserted {
            let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            var descriptor = desk_smc_key()
            if desk_smc_describe(connection, code, &descriptor) { descriptors[key] = descriptor }
        }
        guard let descriptor = descriptors[key] else { return nil }
        var value: Double = 0
        guard desk_smc_read(connection, descriptor, &value), range.contains(value) else { return nil }
        return value
    }
}
