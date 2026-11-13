import Combine
import Darwin
import Foundation

@MainActor
final class GarminLogin: ObservableObject {
    struct Runtime: Sendable { let python: URL; let script: URL; let packages: URL }
    enum State: Equatable { case idle, signingIn, verification, failed, complete }
    @Published private(set) var state: State = .idle
    @Published private(set) var message = ""
    var busy: Bool { state == .signingIn || state == .verification }
    private let store: GarminSessionStore
    private let runtime: Runtime?
    private var process: Process?
    private var input: FileHandle?
    private var candidate: String?
    private var generation = UUID()
    private var success: ((String) -> Void)?

    init(store: GarminSessionStore = .init(), runtime: Runtime? = nil) { self.store = store; self.runtime = runtime }

    func start(email: String, password: String, success: @escaping (String) -> Void) {
        cancel()
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            state = .failed; message = "请填写佳明中国区账号和密码。"; return
        }
        let resolved = runtime ?? BundledPython.executable().flatMap { python in
            Bundle.main.url(forResource: "garmin_auth", withExtension: "py").flatMap { script in
                Bundle.main.resourceURL.map { Runtime(python: python, script: script,
                                                      packages: $0.appendingPathComponent("garmin-packages")) }
            }
        }
        guard let resolved else {
            state = .failed; message = "缺少内置登录程序，请重新安装完整应用。"; return
        }
        let generation = self.generation
        do {
            let id = try store.create()
            candidate = id
            let process = Process(), incoming = Pipe(), outgoing = Pipe()
            process.executableURL = resolved.python
            process.arguments = ["-B", "-s", "-u", resolved.script.path, "--session-file", try store.file(for: id).path]
            process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                                   "PYTHONPATH": resolved.packages.path,
                                   "PYTHONNOUSERSITE": "1"]
            process.standardInput = incoming
            process.standardOutput = outgoing
            process.standardError = FileHandle.nullDevice
            try process.run()
            self.process = process
            input = incoming.fileHandleForWriting
            _ = fcntl(incoming.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            self.success = success
            state = .signingIn; message = "正在连接佳明中国区…"
            let reader = outgoing.fileHandleForReading
            Task.detached(priority: .utility) { [weak self] in
                var buffer = Data(), receivedSuccess = false, invalid = false
                var bytes = [UInt8](repeating: 0, count: 4096)
                while true {
                        // FileHandle.read(upToCount:) can wait to fill the buffer on a pipe.
                        // A login challenge must be delivered before the helper can continue.
                        let count = Darwin.read(reader.fileDescriptor, &bytes, bytes.count)
                        if count < 0 && errno == EINTR { continue }
                        if count < 0 { invalid = true; break }
                        if count == 0 { break }
                        buffer.append(contentsOf: bytes.prefix(count))
                        guard buffer.count <= 16_384 else { invalid = true; break }
                        while let newline = buffer.firstIndex(of: 10) {
                            let line = Data(buffer[..<newline])
                            buffer.removeSubrange(...newline)
                            guard let event = try? JSONDecoder().decode(Event.self, from: line) else {
                                invalid = true; break
                            }
                            if event.type == "success" { receivedSuccess = true }
                            await self?.receive(event, generation: generation)
                        }
                        if invalid { break }
                }
                if invalid && process.isRunning { process.terminate() }
                process.waitUntilExit()
                try? reader.close()
                await self?.finish(generation: generation, passed: !invalid && receivedSuccess && process.terminationStatus == 0)
            }
            try send(["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password])
        } catch {
            cancel(); state = .failed; message = "无法启动登录，请重试。"
        }
    }

    func verify(_ code: String) {
        guard state == .verification else { return }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, code.count <= 32 else { message = "请输入验证码。"; return }
        do {
            try send(["code": code]); state = .signingIn; message = "正在验证…"
        } catch { cancel(); state = .failed; message = "登录已结束，请重新登录。" }
    }

    func cancel() {
        generation = UUID()
        try? input?.close(); input = nil
        if let process, process.isRunning {
            process.terminate()
            Task { // Ensure a cancelled helper cannot stay alive waiting for input/network.
                try? await Task.sleep(for: .seconds(1))
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        if let candidate { try? store.remove(candidate) }
        candidate = nil; success = nil
        state = .idle; message = ""
    }

    private func send(_ value: [String: String]) throws {
        guard let input else { throw CocoaError(.fileWriteUnknown) }
        var data = try JSONSerialization.data(withJSONObject: value)
        guard data.count < 16_384 else { throw CocoaError(.fileWriteUnknown) }
        data.append(10)
        try input.write(contentsOf: data)
    }
    private struct Event: Decodable, Sendable { let type: String; let code: String? }
    private func receive(_ event: Event, generation: UUID) {
        guard generation == self.generation else { return }
        switch event.type {
        case "mfa": state = .verification; message = "佳明要求验证，请输入收到的验证码。"
        case "error":
            state = .failed
            switch event.code {
            case "authentication": message = "登录未通过，请检查账号、密码或验证码。"
            case "rate_limit": message = "尝试过于频繁，请稍后再登录。"
            case "timeout": message = "登录超时，请重新登录。"
            case "invalid": message = "登录信息或返回的会话无效，请重新登录。"
            default: message = "暂时无法完成中国区登录，请稍后重试。"
            }
        default: break
        }
    }
    private func finish(generation: UUID, passed: Bool) {
        guard generation == self.generation else { return }
        try? input?.close(); input = nil; process = nil
        if passed, let id = candidate, store.hasSession(id) {
            candidate = nil
            let callback = success; success = nil
            state = .complete; message = "登录成功，会话已由桌屿保存。"
            callback?(id)
        } else {
            if let candidate { try? store.remove(candidate) }
            candidate = nil; success = nil
            if state != .failed { state = .failed; message = "登录未完成，请重试。" }
        }
    }
}
