import Darwin
import Foundation

struct CodexQuota: Decodable, Equatable, Sendable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Int64?

    var remainingPercent: Int? {
        usedPercent.map { Int((100 - min(100, max(0, $0))).rounded()) }
    }

    var resetLabel: String? {
        guard let resetsAt, resetsAt > 0 else { return nil }
        let date = Date(timeIntervalSince1970: Double(resetsAt))
        let format = Date.FormatStyle.dateTime.month(.defaultDigits).day()
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "zh_CN"))
        return date.formatted(format)
    }
}

struct CodexCardData: Equatable, Sendable {
    let day: String
    let plan: String?
    let week: CodexQuota?
    let fiveHours: CodexQuota?
    let tokens: Int64?
    let localTokens: Bool
    let staleQuotas: Bool

    struct ReadResult: Sendable {
        let data: CodexCardData?
        let status: ConnectionStatus
    }

    static func fetch(configuration: CodexConnection, previous: Self?) async -> ReadResult {
        guard configuration.enabled else { return ReadResult(data: nil, status: .disabled) }
        let worker = Task.detached(priority: .utility) {
            let account = try? CodexAccountProbe.read(configuration: configuration)
            let now = Date()
            let calendar = Calendar.current
            let day = now.formatted(Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day())
            let official = account?.dailyUsage.first { $0.startDate.prefix(10) == day }?.tokens
            let local = official == nil && !Task.isCancelled
                ? CodexLocalTokens.read(from: calendar.startOfDay(for: now), through: now,
                                        codexHome: configuration.homeURL()) : nil
            let earlierToday = previous?.day == day ? previous : nil
            let quotas = account?.quotas
            let plan = [quotas?.planType, account?.plan].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && $0.lowercased() != "unknown" }
            let data = Self(day: day, plan: plan ?? (account == nil ? previous?.plan : nil),
                        week: quotas == nil ? previous?.week : quotas?.window(near: 7 * 24 * 60, within: 24 * 60),
                        fiveHours: quotas == nil ? previous?.fiveHours : quotas?.window(near: 5 * 60, within: 60),
                        tokens: official ?? local ?? earlierToday?.tokens,
                        localTokens: official == nil && (local != nil || earlierToday?.localTokens == true),
                        staleQuotas: quotas == nil && (previous?.week != nil || previous?.fiveHours != nil))
            let status: ConnectionStatus
            if quotas != nil {
                status = .init(kind: .ready, title: "已连接", detail: "订阅额度已更新。今日 Token 会注明账号统计或本机统计。")
            } else if configuration.executableURL() == nil {
                status = .init(kind: local == nil ? .setup : .partial, title: "未找到 Codex 程序",
                               detail: local == nil ? "安装 Codex，或在高级设置中选择程序。" : "可读取本机会话；订阅额度需要安装 Codex 并登录。")
            } else if account?.hasAccount == false {
                status = .init(kind: .setup, title: "需要在 Codex 登录", detail: "请在 Codex 中完成登录，再检查连接。桌屿不保存你的 Codex 密码。")
            } else {
                status = .init(kind: local == nil ? .unavailable : .partial,
                               title: local == nil ? "用量暂不可用" : "仅本机统计",
                               detail: "订阅额度暂时无法读取。请确认 Codex 已登录且为较新版本，然后重试。")
            }
            return ReadResult(data: data, status: status)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

// Account selection and the stdio probe follow Dboard's Codex usage service.
private enum CodexAccountProbe {
    struct Report {
        let hasAccount: Bool
        let plan: String?
        let quotas: Quotas?
        let dailyUsage: [Day]
    }

    struct Quotas: Decodable {
        let limitId: String?
        let planType: String?
        let primary: CodexQuota?
        let secondary: CodexQuota?

        func window(near minutes: Int, within tolerance: Int) -> CodexQuota? {
            [primary, secondary].compactMap { $0 }.first {
                guard let duration = $0.windowDurationMins, $0.usedPercent != nil else { return false }
                return (minutes - tolerance...minutes + tolerance).contains(duration)
            }
        }
    }

    struct Day: Decodable {
        let startDate: String
        let tokens: Int64
    }

    private struct Response<Result: Decodable>: Decodable { let result: Result? }
    private struct ResponseID: Decodable { let id: Int }
    private struct Initialized: Decodable {}
    private struct Account: Decodable {
        struct Details: Decodable { let planType: String? }
        let account: Details?
    }
    private struct Limits: Decodable {
        let rateLimits: Quotas?
        let rateLimitsByLimitId: [String: Quotas]?

        var codex: Quotas? {
            if let codex = rateLimitsByLimitId?["codex"] { return codex }
            if let rateLimits, rateLimits.limitId == nil || rateLimits.limitId == "codex" { return rateLimits }
            return rateLimitsByLimitId?.values.first { $0.limitId == "codex" }
        }
    }
    private struct Usage: Decodable { let dailyUsageBuckets: [Day]? }

    static func read(configuration: CodexConnection) throws -> Report? {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard let executable = configuration.executableURL() else { return nil }
        environment["PATH"] = (paths + ["/usr/bin", "/bin"]).joined(separator: ":")
        environment["CODEX_HOME"] = configuration.homeURL().path

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = home
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        defer {
            try? writer.close()
            try? reader.close()
            if process.isRunning { process.terminate() }
        }

        let deadline = ProcessInfo.processInfo.systemUptime + 15
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var buffer = Data()
        var replies = [Int: Data]()
        var bytes = [UInt8](repeating: 0, count: 16_384)

        func receive(_ ids: Set<Int>) {
            var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
            while !Task.isCancelled && !ids.isSubset(of: replies.keys) {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return }
                let ready = Darwin.poll(&descriptor, 1, Int32(min(250, max(1, remaining * 1_000))))
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0, descriptor.revents & Int16(POLLIN | POLLHUP) != 0 else { return }
                let count = Darwin.read(reader.fileDescriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                buffer.append(contentsOf: bytes.prefix(count))
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    if let response = try? decoder.decode(ResponseID.self, from: line), ids.contains(response.id) {
                        replies[response.id] = line
                    }
                }
                if buffer.count > 1_048_576 { return }
            }
        }

        func result<Value: Decodable>(_ id: Int, as type: Value.Type) -> Value? {
            guard let line = replies[id] else { return nil }
            return (try? decoder.decode(Response<Value>.self, from: line))?.result
        }

        let initialize = #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"deskisle","title":"DeskIsle","version":"1.0.0"}}}"#
        try writer.write(contentsOf: Data((initialize + "\n").utf8))
        receive([0])
        guard result(0, as: Initialized.self) != nil, !Task.isCancelled else { return nil }

        let requests = """
        {"method":"initialized"}
        {"method":"account/read","id":1,"params":{"refreshToken":false}}
        {"method":"account/rateLimits/read","id":2}
        {"method":"account/usage/read","id":3}
        """
        try writer.write(contentsOf: Data((requests + "\n").utf8))
        receive([1, 2, 3])
        return Report(hasAccount: result(1, as: Account.self)?.account != nil,
                      plan: result(1, as: Account.self)?.account?.planType,
                      quotas: result(2, as: Limits.self)?.codex,
                      dailyUsage: result(3, as: Usage.self)?.dailyUsageBuckets ?? [])
    }
}
