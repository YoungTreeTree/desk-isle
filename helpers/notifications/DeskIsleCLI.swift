import CryptoKit
import Darwin
import Foundation

@main
struct DeskIsleCLI {
    private static let usage = """
        deskisle notify --title TEXT [--source ID] [--body TEXT] [--level info|success|warning|error] [--ttl-ms MS]
        deskisle event --stdin
        """

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["hook", "codex"] {
            forwardCodexHook()
            return
        }
        if arguments.isEmpty || arguments == ["--help"] {
            print(usage)
            return
        }
        do {
            let event: NotificationEvent
            if arguments == ["event", "--stdin"] {
                guard let data = try readInput(limit: NotificationSocket.packetLimit) else {
                    throw NotificationSocket.Failure.invalid
                }
                event = try JSONDecoder().decode(NotificationEvent.self, from: data)
            } else if arguments.first == "notify", let post = notification(Array(arguments.dropFirst())) {
                event = post
            } else {
                FileHandle.standardError.write(Data((usage + "\n").utf8))
                exit(2)
            }
            try NotificationSocket.send(event)
            let receipt = try JSONEncoder().encode(["status": "accepted", "event_id": event.eventID])
            FileHandle.standardOutput.write(receipt + Data([10]))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func notification(_ arguments: [String]) -> NotificationEvent? {
        guard arguments.count.isMultiple(of: 2) else { return nil }
        let flags = ["--source", "--title", "--body", "--level", "--ttl-ms"]
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let flag = arguments[index]
            guard flags.contains(flag), values[flag] == nil else { return nil }
            values[flag] = arguments[index + 1]
        }
        guard let title = values["--title"] else { return nil }
        let level = values["--level"].flatMap(NotificationEvent.Level.init(rawValue:))
        let ttl = values["--ttl-ms"].flatMap { Int($0) }
        guard values["--level"] == nil || level != nil, values["--ttl-ms"] == nil || ttl != nil else { return nil }
        return NotificationEvent(type: .post, source: values["--source"] ?? "deskisle", title: title,
                                 body: values["--body"], level: level, ttlMS: ttl)
    }

    private static func readInput(limit: Int) throws -> Data? {
        var data = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 8_192), !chunk.isEmpty {
            guard data.count + chunk.count <= limit else { return nil }
            data.append(chunk)
        }
        return data
    }

    private static func forwardCodexHook() {
        guard let data = try? readInput(limit: 2 * 1_024 * 1_024),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = payload["hook_event_name"] as? String else { return }
        defer {
            if name == "Stop" { print("{}") }
        }
        if let event = codexEvent(name: name, payload: payload) {
            try? NotificationSocket.send(event)
        }
    }

    private static func codexEvent(name: String, payload: [String: Any]) -> NotificationEvent? {
        guard let session = payload["session_id"] as? String else { return nil }
        let turn = payload["turn_id"] as? String
        let cwd = (payload["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        let project = NotificationEvent.displayText(cwd, limit: 48)
        let tool = payload["tool_name"] as? String ?? ""
        let kind: NotificationEvent.Kind
        var title: String?
        var body: String?
        var outcome: NotificationEvent.Outcome?
        var requestID: String?
        switch name {
        case "SessionStart":
            kind = .sessionOpened
        case "SessionEnd":
            kind = .sessionClosed
        case "UserPromptSubmit":
            kind = .turnStarted
            title = excerpt(payload["prompt"], limit: 64)
        case "Stop":
            kind = .turnFinished
            outcome = .completed
            body = excerpt(payload["last_assistant_message"], limit: 320) ?? "Codex 已完成这一轮回复"
        case "Interrupt":
            kind = .turnFinished
            outcome = .interrupted
            body = "这一轮已中断"
        case "PermissionRequest", "PostToolUse":
            kind = name == "PermissionRequest" ? .attentionRequested : .attentionResolved
            guard let input = payload["tool_input"] else { return nil }
            let fields = input as? [String: Any]
            let identity = fields?["command"] ?? input
            guard let arguments = try? JSONSerialization.data(withJSONObject: identity,
                                                              options: [.sortedKeys, .fragmentsAllowed]) else { return nil }
            // Codex permission hooks do not always carry the tool call's ID.
            // Match the same tool and arguments within a turn without displaying them.
            requestID = SHA256.hash(data: Data(tool.utf8) + Data([0]) + arguments)
                .map { String(format: "%02x", $0) }.joined()
            let action = switch tool {
            case "Bash": "运行命令"
            case "apply_patch": "修改文件"
            default: "调用工具"
            }
            let detail = excerpt(fields?["description"] ?? payload["reason"], limit: 220)
            if kind == .attentionRequested {
                body = detail.map { "\(action) · \($0)" } ?? "等待确认是否\(action)"
            } else {
                body = detail.map { "已\(action) · \($0)" } ?? "已\(action)"
            }
        default:
            return nil
        }
        return NotificationEvent(type: kind, source: "codex", sessionID: session, turnID: turn, requestID: requestID,
                                 requestKind: kind == .attentionRequested ? .approval : nil,
                                 outcome: outcome, project: project.isEmpty ? nil : project, title: title, body: body)
    }

    private static func excerpt(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String else { return nil }
        var fence: String?
        var lines: [String] = []
        for rawLine in text.prefix(2_000).split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                if line.hasPrefix(marker) { fence = nil }
            } else if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fence = String(line.prefix(3))
            } else {
                lines.append(line)
            }
        }
        let markdown = lines.joined(separator: "\n")
            .replacingOccurrences(of: #"(?m)^(?:#{1,6}|[-*+>])\s+"#, with: "", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let plain = (try? AttributedString(markdown: markdown, options: options)).map { String($0.characters) } ?? markdown
        let result = NotificationEvent.displayText(plain, limit: limit)
        return result.isEmpty ? nil : result
    }
}
