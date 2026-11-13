import Foundation
import Combine

struct CodexConnection: Codable, Equatable, Sendable {
    var enabled = false
    var executable: String?
    var home: String?

    func homeURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                 userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let path = home ?? environment["CODEX_HOME"]
        return path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? userHome.appendingPathComponent(".codex", isDirectory: true)
    }

    func executableURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                       userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        // An explicit invalid selection must be reported, not silently replaced by another installation.
        if let executable { return Self.executableFile(executable) }
        if let configured = environment["CODEX_BINARY_PATH"], !configured.isEmpty {
            return Self.executableFile(configured)
        }
        let applications = ["/Applications", userHome.appendingPathComponent("Applications").path]
            .flatMap { directory in ["Codex.app", "ChatGPT.app"].map { "\(directory)/\($0)/Contents/Resources/codex" } }
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", userHome.appendingPathComponent(".local/bin").path]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (applications + directories.map { "\($0)/codex" }).compactMap(Self.executableFile).first
    }

    private static func executableFile(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.isExecutableFile(atPath: url.path),
              (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }
}

struct GarminConnection: Codable, Equatable, Sendable {
    var enabled = false
    var sessionID: String?
    var sessionDirectory: String?

    init() {}

    private enum CodingKeys: String, CodingKey { case enabled, sessionID, sessionDirectory, region }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let previousRegion = try values.decodeIfPresent(String.self, forKey: .region)
        // Preserve existing China profiles. Never reinterpret an old global account as China.
        if previousRegion == nil || previousRegion == "china" {
            enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
            sessionDirectory = try values.decodeIfPresent(String.self, forKey: .sessionDirectory)
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encodeIfPresent(sessionID, forKey: .sessionID)
        try values.encodeIfPresent(sessionDirectory, forKey: .sessionDirectory)
    }

    var sessionFile: URL? { sessionID.flatMap { try? GarminSessionStore().file(for: $0) } }
    var hasSavedSession: Bool { GarminSessionStore().hasSession(sessionID) }
}

enum ConnectionPaths {
    static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.deskisle.layout", isDirectory: true)
    }
    static var notificationHelper: URL { support.appendingPathComponent("bin/deskisle") }
}

struct ConnectionProfile: Codable, Equatable {
    var version = 1
    var setupComplete = false
    var codex = CodexConnection()
    var garmin = GarminConnection()
}

struct ConnectionStatus: Equatable, Sendable {
    enum Kind: Sendable { case disabled, setup, checking, ready, partial, unavailable }
    let kind: Kind
    let title: String
    let detail: String
    static let checking = Self(kind: .checking, title: "正在检查", detail: "正在验证连接，请稍候。")
    static let disabled = Self(kind: .disabled, title: "未启用", detail: "启用后才会读取此数据源。")
}

@MainActor
final class ConnectionSettings: ObservableObject {
    static let key = "connections.profile.v1"
    @Published private(set) var profile: ConnectionProfile
    @Published var codexStatus: ConnectionStatus = .disabled
    @Published var garminStatus: ConnectionStatus = .disabled
    @Published var hooksStatus = ConnectionStatus(kind: .setup, title: "尚未接入", detail: "连接 Codex 通知后，通知岛会跟随任务更新。")
    @Published var hookOperation = false
    @Published private(set) var persistenceError: String?
    @Published private(set) var garminSessionNotice: String?
    let garminLogin: GarminLogin
    let localPlugins: LocalPluginSettings
    private let garminStore: GarminSessionStore
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard, inspectConnections: Bool = true,
         garminStore: GarminSessionStore = .init()) {
        self.preferences = preferences
        self.garminStore = garminStore
        self.garminLogin = GarminLogin(store: garminStore)
        self.localPlugins = LocalPluginSettings(preferences: preferences)
        if let data = preferences.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(ConnectionProfile.self, from: data), saved.version == 1 {
            profile = saved
        } else {
            // Run before PetSettings creates its defaults, so a new installation stays opt-in.
            let legacy = preferences.data(forKey: Self.key) == nil &&
                (preferences.object(forKey: "pet.skin") != nil || preferences.object(forKey: "displayBrightness") != nil)
            var initial = ConnectionProfile()
            initial.setupComplete = legacy
            initial.codex.enabled = legacy
            initial.garmin.enabled = legacy
            if legacy {
                initial.garmin.sessionDirectory = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".garminconnect").path
            }
            profile = initial
            if preferences.data(forKey: Self.key) == nil { save() }
            else { persistenceError = "连接配置无法读取。请检查设置后重新保存。" }
        }
        if inspectConnections { migrateGarminSession(); inspect() }
    }

    func updateCodex(_ change: (inout CodexConnection) -> Void) {
        var updated = profile; change(&updated.codex); profile = updated; save(); inspectCodex(); inspectHooks()
    }
    func updateGarmin(_ change: (inout GarminConnection) -> Void) {
        var updated = profile; change(&updated.garmin); profile = updated; save(); inspectGarmin()
    }
    func completeSetup() { profile.setupComplete = true; save() }

    private func migrateGarminSession() {
        guard profile.garmin.sessionID == nil, let path = profile.garmin.sessionDirectory else { return }
        importGarminSession(URL(fileURLWithPath: (path as NSString).expandingTildeInPath), enable: profile.garmin.enabled)
    }

    func importGarminSession(_ directory: URL, enable: Bool = true) {
        do {
            let id = try garminStore.importLegacy(directory: directory)
            adoptGarminSession(id, enable: enable)
            garminSessionNotice = "已有会话已迁入桌屿，原目录保持不变。"
        } catch { garminSessionNotice = "无法导入会话。请登录佳明中国区，或选择有效的旧会话。" }
    }

    func signInGarmin(email: String, password: String) {
        garminLogin.start(email: email, password: password) { [weak self] id in self?.adoptGarminSession(id) }
    }

    private func adoptGarminSession(_ id: String, enable: Bool = true) {
        let previous = profile.garmin.sessionID
        updateGarmin { $0.sessionID = id; $0.sessionDirectory = nil; $0.enabled = enable }
        garminSessionNotice = nil
        if let previous, previous != id { try? garminStore.remove(previous) }
    }

    func disconnectGarmin() {
        garminLogin.cancel()
        do {
            if let id = profile.garmin.sessionID { try garminStore.remove(id) }
            updateGarmin { $0 = GarminConnection() }
            garminSessionNotice = "已退出并清除桌屿保存的会话。"
        } catch { garminSessionNotice = "会话暂时无法清除，请重试。" }
    }

    private func save() {
        do { preferences.set(try JSONEncoder().encode(profile), forKey: Self.key); persistenceError = nil }
        catch { persistenceError = "暂时无法保存连接配置。" }
    }

    func inspect() { inspectCodex(); inspectGarmin(); inspectHooks() }
    func inspectCodex() {
        guard profile.codex.enabled else { codexStatus = .disabled; return }
        guard profile.codex.executableURL() != nil else {
            codexStatus = .init(kind: .setup, title: "未找到 Codex", detail: "安装 Codex 桌面版或 CLI，也可以在高级设置中选择程序。")
            return
        }
        codexStatus = .init(kind: .setup, title: "已找到 Codex", detail: "点击检查连接，验证当前登录与用量数据。")
    }
    func inspectGarmin() {
        guard profile.garmin.enabled else { garminStatus = .disabled; return }
        guard BundledPython.executable() != nil else {
            garminStatus = .init(kind: .unavailable, title: "缺少内置运行环境", detail: "请重新安装完整的桌屿应用。")
            return
        }
        garminStatus = garminStore.hasSession(profile.garmin.sessionID)
            ? .init(kind: .setup, title: "会话已保存", detail: "桌屿在本机管理登录会话，可检查连接状态。")
            : .init(kind: .setup, title: "尚未登录", detail: "登录佳明中国区账号，桌屿会自动保管会话。")
    }

    func inspectHooks() {
        hooksStatus = CodexHookConnection.inspect(home: profile.codex.homeURL())
    }

    func configureHooks(remove: Bool) {
        guard !hookOperation else { return }
        hookOperation = true
        let home = profile.codex.homeURL()
        Task {
            let result = await CodexHookConnection.configure(home: home, remove: remove)
            hookOperation = false
            guard home == profile.codex.homeURL() else { return }
            hooksStatus = result
        }
    }
}

enum BundledPython {
    static func executable(bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let file = resources.appendingPathComponent("runtime/bin/python3.11")
        return FileManager.default.isExecutableFile(atPath: file.path) ? file : nil
    }
}
