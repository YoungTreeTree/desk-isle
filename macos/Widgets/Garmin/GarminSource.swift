import Foundation

struct GarminSnapshot: Codable, Equatable, Sendable {
    let fetchedAt: TimeInterval
    let lastSyncAt: TimeInterval?
    let steps: Int?
    let stepGoal: Int?
    let sleepSeconds: Int?
    let sleepScore: Int?
    let bodyBattery: Int?
    let restingHeartRate: Int?
    let hrv: Int?
    let stress: [Int?]
}

enum GarminReadError: String, Error {
    case disabled = "请在插件配置中启用佳明"
    case setup = "请先连接佳明账号"
    case login = "需要佳明登录"
    case region = "仅支持佳明中国区登录"
    case runtime = "佳明运行环境不可用"
    case unavailable = "佳明数据暂不可用"
}

enum GarminSource {
    static func fetch(configuration: GarminConnection) async -> Result<GarminSnapshot, GarminReadError> {
        guard configuration.enabled else { return .failure(.disabled) }
        guard configuration.hasSavedSession else { return .failure(.setup) }
        return await Task.detached(priority: .utility) { readSnapshot(configuration: configuration) }.value
    }

    private static func readSnapshot(configuration: GarminConnection) -> Result<GarminSnapshot, GarminReadError> {
        let bundle = Bundle.main
        guard let python = BundledPython.executable(bundle: bundle),
              let script = bundle.url(forResource: "garmin_snapshot", withExtension: "py"),
              let resources = bundle.resourceURL else { return .failure(.runtime) }
        guard let session = configuration.sessionFile else { return .failure(.setup) }

        let output = Pipe()
        let process = Process()
        process.executableURL = python
        process.arguments = ["-B", "-s", script.path, "--session-file", session.path]
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PYTHONPATH": resources.appendingPathComponent("garmin-packages").path,
            "PYTHONNOUSERSITE": "1",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Read while the helper runs. The helper bounds the network read with an alarm.
            let data = try output.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            guard process.terminationReason == .exit else { return .failure(.unavailable) }
            switch process.terminationStatus {
            case 0:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return .success(try decoder.decode(GarminSnapshot.self, from: data))
            case 2: return .failure(.login)
            case 3: return .failure(.runtime)
            case 4: return .failure(.region)
            default: return .failure(.unavailable)
            }
        } catch {
            return .failure(.unavailable)
        }
    }
}
