import Foundation

enum CodexHookConnection {
    static let events = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SessionEnd"]

    static func command(for helper: URL) -> String {
        let path = helper.path
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        let quoted = path.unicodeScalars.allSatisfy(safe.contains)
            ? path : "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        return quoted + " hook codex"
    }

    static func inspect(home: URL, helper: URL = ConnectionPaths.notificationHelper,
                        legacyHelper: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/deskisle")) -> ConnectionStatus {
        let path = home.appendingPathComponent("hooks.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .init(kind: .setup, title: "尚未接入", detail: "连接后会添加桌屿的通知 Hook，并备份现有配置。")
        }
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["hooks"] == nil || json["hooks"] is [String: Any] else {
            return .init(kind: .unavailable, title: "无法读取通知配置", detail: "请检查 Codex 的 hooks.json 格式，桌屿不会覆盖无法识别的内容。")
        }
        let hooks = json["hooks"] as? [String: Any] ?? [:]
        func count(_ command: String) -> Int {
            events.filter { event in
                (hooks[event] as? [[String: Any]] ?? []).contains { group in
                    (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
                }
            }.count
        }
        let managed = count(command(for: helper))
        let legacy = count(command(for: legacyHelper))
        if managed == events.count, FileManager.default.isExecutableFile(atPath: helper.path) {
            return .init(kind: .ready, title: "通知接口已安装", detail: "仍需在 Codex 的 Hook 设置中审核并信任。可发送测试通知检查小屏。")
        }
        if legacy == events.count {
            return .init(kind: .partial, title: "已接入旧通知命令", detail: "可修复连接，将通知命令放到固定位置，避免移动应用后失效。")
        }
        return .init(kind: .setup, title: managed + legacy == 0 ? "尚未接入" : "通知接口需要修复",
                     detail: "只会调整桌屿自己的 Hook，保留其他通知配置。")
    }

    static func configure(home: URL, remove: Bool) async -> ConnectionStatus {
        await Task.detached(priority: .utility) {
            let bundle = Bundle.main
            guard let python = BundledPython.executable(bundle: bundle),
                  let script = bundle.url(forResource: "install-codex-notifications", withExtension: "py") else {
                return ConnectionStatus(kind: .unavailable, title: "缺少内置运行环境", detail: "请重新安装完整的桌屿应用。")
            }
            let helper = ConnectionPaths.notificationHelper
            let original = bundle.bundleURL.appendingPathComponent("Contents/Helpers/deskisle")
            do {
                if !remove {
                    try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    guard (try? helper.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    try Data(contentsOf: original).write(to: helper, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
                }
                let process = Process(), output = Pipe()
                process.executableURL = python
                process.arguments = ["-I", "-B", script.path, "--app", bundle.bundleURL.path,
                                     "--helper", helper.path, "--codex-home", home.path,
                                     "--previous-command", command(for: original)] + (remove ? ["--uninstall"] : [])
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = output
                try process.run()
                _ = try output.fileHandleForReading.readToEnd()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
                return inspect(home: home)
            } catch {
                return ConnectionStatus(kind: .unavailable, title: "通知配置未完成",
                                        detail: "请检查 Codex 配置目录是否可写、hooks.json 是否有效，然后重试。")
            }
        }.value
    }
}
