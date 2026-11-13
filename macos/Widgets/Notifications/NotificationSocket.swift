import Darwin
import Foundation

enum NotificationSocket {
    static let packetLimit = 16_384

    enum Failure: LocalizedError {
        case unavailable, busy, invalid, path

        var errorDescription: String? {
            switch self {
            case .unavailable: "桌屿的本地通知入口未连接。"
            case .busy: "桌屿的本地通知入口暂时无响应。"
            case .invalid: "通知事件无效。"
            case .path: "无法创建桌屿的本地通知入口。"
            }
        }
    }

    private static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.deskisle.layout/notifications", isDirectory: true)
    }

    private static var path: String { directory.appendingPathComponent("events.sock").path }

    static func listen(receive: @escaping @Sendable (NotificationEvent) -> Void) throws -> DispatchSourceRead {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure.path }
        let lock = open(directory.appendingPathComponent("listener.lock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw Failure.path }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw Failure.busy
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        do {
            guard fd >= 0, configure(fd) else { throw Failure.path }
            unlink(path)
            let bound = try address { bind(fd, $0, $1) }
            guard bound == 0, Darwin.listen(fd, 16) == 0 else { throw Failure.path }
        } catch {
            if fd >= 0 { close(fd) }
            unlink(path)
            close(lock)
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd,
                                                   queue: DispatchQueue(label: "com.deskisle.notifications", qos: .userInitiated))
        source.setEventHandler {
            let peer = accept(fd, nil, nil)
            guard peer >= 0 else { return }
            defer { close(peer) }
            guard configure(peer), isOwnUser(peer) else { return }
            var reply: UInt8 = 0
            if let packet = readPacket(peer),
               let event = try? JSONDecoder().decode(NotificationEvent.self, from: packet), event.isValid {
                receive(event)
                reply = 1
            }
            _ = Darwin.send(peer, &reply, 1, 0)
        }
        source.setCancelHandler {
            unlink(path)
            close(fd)
            close(lock)
        }
        source.resume()
        return source
    }

    static func send(_ event: NotificationEvent) throws {
        guard event.isValid else { throw Failure.invalid }
        let data = try JSONEncoder().encode(event)
        guard data.count <= packetLimit else { throw Failure.invalid }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd) }
        guard configure(fd) else { throw Failure.unavailable }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        let connected = try address { connect(fd, $0, $1) }
        if connected != 0 {
            guard errno == EINPROGRESS, wait(fd, for: POLLOUT, until: deadline) else { throw Failure.unavailable }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                throw Failure.unavailable
            }
        }
        guard isOwnUser(fd) else { throw Failure.unavailable }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard wait(fd, for: POLLOUT, until: deadline), let base = bytes.baseAddress else { throw Failure.busy }
                let count = Darwin.send(fd, base.advanced(by: offset), bytes.count - offset, 0)
                guard count > 0 else { throw Failure.busy }
                offset += count
            }
        }
        guard shutdown(fd, SHUT_WR) == 0, wait(fd, for: POLLIN, until: deadline) else { throw Failure.busy }
        var reply: UInt8 = 0
        guard recv(fd, &reply, 1, 0) == 1 else { throw Failure.busy }
        guard reply == 1 else { throw Failure.invalid }
    }

    private static func address<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.path }
        let length = MemoryLayout<sockaddr_un>.size
        address.sun_len = UInt8(length)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(length)) }
        }
    }

    private static func configure(_ fd: Int32) -> Bool {
        var enabled: Int32 = 1
        return fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 && fcntl(fd, F_SETFL, O_NONBLOCK) == 0 &&
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private static func isOwnUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    private static func wait(_ fd: Int32, for events: Int32, until deadline: TimeInterval) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
        return poll(&descriptor, 1, Int32((remaining * 1_000).rounded(.up))) > 0
    }

    private static func readPacket(_ fd: Int32) -> Data? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while wait(fd, for: POLLIN, until: deadline) {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count == 0 { return data }
            guard count > 0, data.count + count <= packetLimit else { return nil }
            data.append(contentsOf: chunk.prefix(count))
        }
        return nil
    }
}
