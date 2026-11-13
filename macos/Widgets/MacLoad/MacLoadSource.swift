import Darwin
import Foundation
import IOKit

struct MacLoadSnapshot: Equatable, Sendable {
    enum MemoryPressure: String, Sendable {
        case normal, warning, critical, unknown

        var label: String {
            switch self {
            case .normal: "内存正常"
            case .warning: "内存紧张"
            case .critical: "内存严重"
            case .unknown: "内存 —"
            }
        }
    }

    var cpu: Int?
    var gpu: Int?
    var cpuTemperature: Int?
    var systemPowerTenths: Int?
    var memoryUsedMiB: Int?
    var memoryTotalMiB: Int?
    var memoryPressure: MemoryPressure = .unknown
    var miucsTenths: Int?
    var deskIsleTenths: Int?
    var cpuHistory: [Int?] = []
    var gpuHistory: [Int?] = []
}

actor MacLoadSource {
    private struct ProcessTime {
        let started: UInt64
        let used: UInt64
    }

    private var previousCPU: [UInt32]?
    private var previousProcesses: [pid_t: ProcessTime] = [:]
    private var sampledAt: Double?
    private var history: [(time: Double, cpu: Int?, gpu: Int?)] = []
    private let sensors = MacHardwareSensors()

    func sample(miucs: [pid_t]) -> MacLoadSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let ticks = Self.cpuTicks()
        var cpu: Int?
        if let ticks, let previousCPU {
            let delta = zip(ticks, previousCPU).map { UInt64($0 &- $1) }
            let total = delta.reduce(0, +)
            if total > 0 { cpu = Int((100 * Double(total - delta[Int(CPU_STATE_IDLE)]) / Double(total)).rounded()) }
        }
        previousCPU = ticks

        let deskIsle = getpid()
        var processes: [pid_t: ProcessTime] = [:]
        for pid in miucs + [deskIsle] { processes[pid] = Self.processTime(pid) }
        let elapsed = now - (sampledAt ?? now)
        func processLoad(_ pids: [pid_t]) -> Int? {
            guard elapsed > 0 else { return nil }
            let deltas = pids.compactMap { pid -> UInt64? in
                guard let current = processes[pid], let before = previousProcesses[pid],
                      current.started == before.started, current.used >= before.used else { return nil }
                return current.used - before.used
            }
            guard !deltas.isEmpty else { return nil }
            return Int((Double(deltas.reduce(0, +)) / elapsed / 1_000_000).rounded())
        }
        let miucsLoad = processLoad(miucs)
        let deskIsleLoad = processLoad([deskIsle])
        previousProcesses = processes
        sampledAt = now

        let gpu = Self.gpuLoad()
        let hardware = sensors.sample()
        let memory = Self.memoryUsage()
        history.removeAll { now - $0.time >= 60 }
        history.append((now, cpu, gpu))
        return MacLoadSnapshot(cpu: cpu, gpu: gpu,
                               cpuTemperature: hardware.cpuTemperature, systemPowerTenths: hardware.systemPowerTenths,
                               memoryUsedMiB: memory.used, memoryTotalMiB: memory.total,
                               memoryPressure: Self.memoryPressure(),
                               miucsTenths: miucsLoad, deskIsleTenths: deskIsleLoad,
                               cpuHistory: history.map(\.cpu), gpuHistory: history.map(\.gpu))
    }

    private static func cpuTicks() -> [UInt32]? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(CPU_STATE_MAX)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    }

    private static func processTime(_ pid: pid_t) -> ProcessTime? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        return ProcessTime(started: info.ri_proc_start_abstime, used: info.ri_user_time + info.ri_system_time)
    }

    private static func gpuLoad() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)
            let stats = property?.takeRetainedValue() as? [String: Any]
            if let value = (stats?["Device Utilization %"] as? NSNumber)?.intValue, (0...100).contains(value) {
                return value
            }
        }
        return nil
    }

    private static func memoryPressure() -> MacLoadSnapshot.MemoryPressure {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return .unknown }
        switch value {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    private static func memoryUsage() -> (used: Int?, total: Int) {
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let total = Int(totalBytes / 1_048_576)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (nil, total) }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return (nil, total) }
        // Physical app + wired + compressor memory. File-backed and purgeable cache
        // stays available; uncompressed logical pages and swap aren't added again.
        let resident = Int64(info.active_count) + Int64(info.inactive_count) + Int64(info.speculative_count)
                     + Int64(info.wire_count) + Int64(info.compressor_page_count)
        let cached = Int64(info.purgeable_count) + Int64(info.external_page_count)
        let usedBytes = min(totalBytes, UInt64(max(0, resident - cached)) * UInt64(pageSize))
        return (Int(usedBytes / 1_048_576), total)
    }
}
