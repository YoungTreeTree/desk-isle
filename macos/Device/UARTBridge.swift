#if canImport(DeskIsleNative)
import DeskIsleNative
#endif
import Darwin
import Foundation
import OSLog
import MiucsCore

/// Shares the programming UART between the layout client and Miucs. Each endpoint
/// still reads and writes its normal DeskIsle byte stream.
enum UARTBridge {
    struct Session {
        let layout: Int32
        let animation: AnimationChannel
    }

    /// Transfers an in-process socket pair to the UART thread, without an external Miucs client.
    final class AnimationChannel: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: Int32?
        private var closed = false

        func open() throws -> Int32 {
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw failure }
            guard configureSocket(pair[0]), configureSocket(pair[1]) else {
                pair.forEach { Darwin.close($0) }
                throw failure
            }
            lock.lock()
            guard !closed else {
                lock.unlock(); pair.forEach { Darwin.close($0) }; throw failure
            }
            if let pending { Darwin.close(pending) }
            pending = pair[1]
            lock.unlock()
            return pair[0]
        }

        fileprivate func takePending() -> Int32? {
            lock.lock(); defer { lock.unlock() }
            defer { pending = nil }
            return pending
        }

        fileprivate func shutdown() {
            lock.lock(); defer { lock.unlock() }
            closed = true
            if let pending { Darwin.close(pending) }
            pending = nil
        }
    }
    private static let baud: speed_t = 3_000_000
    private static let chunk = 2048
    private static let delimiter: UInt8 = 0xc0
    private static let escape: UInt8 = 0xdb
    private static let signature = Array("DS2".utf8)
    private static let headerSize = 8
    private static let checksumSize = 4
    private static let log = Logger(subsystem: "com.deskisle.layout", category: "uart")
    private static let failure = LayoutUSBError.message("无法通过 CH343 连接桌屿。")
    private static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.deskisle.layout/uart", isDirectory: true)
    }

    private enum Channel: UInt8 { case animation, layout, credit }

    /// Returns the layout end of a socket pair. Closing it also stops the relay.
    static func start(serialPath: String) throws -> Session? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw failure }
        let flash = open(directory.appendingPathComponent("flash.lock").path,
                         O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard flash >= 0 else { throw failure }
        let owner = open(directory.appendingPathComponent("port.lock").path,
                         O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        var socketPath: String?
        var serial: Int32 = -1
        var listener: Int32 = -1
        var pair: [Int32] = [-1, -1]
        var started = false
        defer {
            if !started {
                if let socketPath { unlink(socketPath) }
                for fd in [serial, listener, pair[0], pair[1], owner, flash] where fd >= 0 { close(fd) }
            }
        }
        guard owner >= 0 else { throw failure }
        guard flock(flash, LOCK_SH | LOCK_NB) == 0, flock(owner, LOCK_EX | LOCK_NB) == 0 else { return nil }
        serial = open(serialPath, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard serial >= 0, configureSerial(serial) else { throw failure }
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0,
              configureSocket(pair[0]), configureSocket(pair[1]) else { throw failure }

        let path = directory.appendingPathComponent("animation.sock").path
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw failure }
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(addressLength)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0, configureSocket(listener) else { throw failure }
        unlink(path)
        socketPath = path
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, addressLength) }
        }
        guard bound == 0, listen(listener, 2) == 0 else { throw failure }

        flock(flash, LOCK_UN)
        let animation = AnimationChannel()
        let relayThread = Thread { [serial, listener, layout = pair[1]] in
            defer {
                animation.shutdown()
                unlink(path)
                for fd in [serial, listener, layout, owner, flash] { close(fd) }
            }
            run(serial: serial, listener: listener, layout: layout, flash: flash, embedded: animation)
        }
        relayThread.name = "DeskIsle UART"
        relayThread.qualityOfService = .userInitiated
        relayThread.start()
        started = true
        return Session(layout: pair[0], animation: animation)
    }

    private static func configureSerial(_ fd: Int32) -> Bool {
        var config = termios()
        guard ioctl(fd, TIOCEXCL) == 0, tcgetattr(fd, &config) == 0 else { return false }
        cfmakeraw(&config)
        config.c_cflag |= tcflag_t(CLOCAL | CREAD)
        config.c_cflag &= ~tcflag_t(HUPCL | CRTSCTS)
        config.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        cfsetspeed(&config, speed_t(B115200))
        guard tcsetattr(fd, TCSANOW, &config) == 0, desk_uart_set_speed(fd, baud) == 0 else { return false }
        // These lines control BOOT and RESET on the board.
        var modem = Int32(TIOCM_DTR | TIOCM_RTS)
        return ioctl(fd, TIOCMBIC, &modem) == 0
    }

    private static func configureSocket(_ fd: Int32) -> Bool {
        var enabled: Int32 = 1
        return fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 && fcntl(fd, F_SETFL, O_NONBLOCK) == 0 &&
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private struct OutputBuffer {
        var data = Data()
        private var offset = 0

        init(_ data: Data = Data()) { self.data = data }

        var isEmpty: Bool { offset == data.count }
        var remaining: Int { data.count - offset }

        mutating func flush(to fd: Int32) -> Bool {
            guard !isEmpty else { return true }
            let count = data.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset)
            }
            if count > 0 {
                offset += count
                if isEmpty { self = OutputBuffer() }
            }
            return count >= 0 || UARTBridge.wouldBlock
        }

        mutating func append(_ payload: Data, limit: Int) -> Bool {
            if offset > 0 && data.count + payload.count > limit {
                data = data.subdata(in: offset..<data.count)
                offset = 0
            }
            guard data.count + payload.count <= limit else { return false }
            data.append(payload)
            return true
        }
    }

    private struct Peer {
        let fd: Int32
        var fragment: Data? = Data() // Open resets the board's parser before the first write.
        var reply = OutputBuffer()

        var pollFD: pollfd {
            var events: Int32 = fragment == nil ? POLLIN : 0
            if !reply.isEmpty { events |= POLLOUT }
            return pollfd(fd: fd, events: Int16(events), revents: 0)
        }

        mutating func service(_ events: Int16) -> Bool {
            if events & UARTBridge.disconnected != 0 { return false }
            if events & Int16(POLLIN) != 0 {
                var data = Data(count: UARTBridge.chunk)
                let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    data.count = count
                    fragment = data
                } else if count == 0 || !UARTBridge.wouldBlock { return false }
            }
            if events & Int16(POLLOUT) != 0, !reply.flush(to: fd) { return false }
            return true
        }

        mutating func appendReply(_ payload: Data) -> Bool {
            reply.append(payload, limit: 64 * 1024)
        }
    }

    private struct Packet {
        let channel: Channel
        let token: UInt16
        let payload: Data
    }

    private struct Decoder {
        var bytes = [UInt8]()
        var escaped = false
        var invalid = false

        mutating func feed(_ data: ArraySlice<UInt8>) -> [Packet] {
            var packets = [Packet]()
            for var byte in data {
                if byte == UARTBridge.delimiter {
                    let end = bytes.count - UARTBridge.checksumSize
                    if !invalid, !escaped, end >= UARTBridge.headerSize, bytes.starts(with: UARTBridge.signature),
                       let channel = Channel(rawValue: bytes[3]),
                       (Int(bytes[6]) | Int(bytes[7]) << 8) == end - UARTBridge.headerSize {
                        let checksum = bytes.withUnsafeBytes {
                            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: end, as: UInt32.self))
                        }
                        if checksum == LayoutUSB.crc32(Data(bytes[..<end])) {
                            packets.append(Packet(channel: channel, token: UInt16(bytes[4]) | UInt16(bytes[5]) << 8,
                                                  payload: Data(bytes[UARTBridge.headerSize..<end])))
                        }
                    }
                    bytes.removeAll(keepingCapacity: true)
                    escaped = false
                    invalid = false
                    continue
                }
                guard !invalid else { continue }
                if escaped {
                    escaped = false
                    switch byte {
                    case 0xdc: byte = UARTBridge.delimiter
                    case 0xdd: byte = UARTBridge.escape
                    default: invalid = true; continue
                    }
                } else if byte == UARTBridge.escape {
                    escaped = true
                    continue
                }
                if bytes.count == UARTBridge.headerSize + UARTBridge.chunk + UARTBridge.checksumSize { invalid = true }
                else { bytes.append(byte) }
            }
            return packets
        }
    }

    private static func frame(_ channel: Channel, token: UInt16, payload: Data) -> Data {
        var body = Data(signature)
        body.append(contentsOf: [channel.rawValue, UInt8(truncatingIfNeeded: token), UInt8(token >> 8),
                                 UInt8(truncatingIfNeeded: payload.count), UInt8(payload.count >> 8)])
        body.append(payload)
        let checksum = LayoutUSB.crc32(body).littleEndian
        withUnsafeBytes(of: checksum) { body.append(contentsOf: $0) }
        var wire = Data(capacity: body.count + 2)
        wire.append(delimiter)
        func append(_ byte: UInt8) {
            switch byte {
            case delimiter: wire.append(contentsOf: [escape, 0xdc])
            case escape: wire.append(contentsOf: [escape, 0xdd])
            default: wire.append(byte)
            }
        }
        body.forEach(append)
        wire.append(delimiter)
        return wire
    }

    private static let disconnected = Int16(POLLERR | POLLHUP | POLLNVAL)
    private static var wouldBlock: Bool { errno == EAGAIN || errno == EINTR }

    private static func acceptAnimation(_ listener: Int32) -> Peer? {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return nil }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(), configureSocket(fd) else {
            close(fd)
            return nil
        }
        return Peer(fd: fd)
    }

    private static func run(serial: Int32, listener: Int32, layout: Int32, flash: Int32, embedded: AnimationChannel) {
        // The screen keeps running when the editor is hidden. App Nap can coalesce
        // this thread's credit/ACK waits beyond the device deadlines. Keep the
        // hardware session responsive without preventing the Mac from sleeping.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                            reason: "向桌屿小屏同步组件和输入事件")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var control = Peer(fd: layout)
        var animation: Peer?
        defer { if let animation { close(animation.fd) } }
        var decoder = Decoder()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var token = UInt16.random(in: 0...UInt16.max)
        var deadline: TimeInterval?
        var retryAt: TimeInterval = 0
        var retryInterval: TimeInterval = 0
        var retryCount = 0
        var lastChannel = Channel.layout
        var inFlight = Data()
        var wire = OutputBuffer()
        var nextFlashCheck: TimeInterval = 0

        while true {
            if let fd = embedded.takePending() {
                if let old = animation { close(old.fd) }
                animation = Peer(fd: fd)
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextFlashCheck {
                guard flock(flash, LOCK_SH | LOCK_NB) == 0 else { return }
                flock(flash, LOCK_UN)
                nextFlashCheck = now + 0.05
            }
            if let deadline, now >= deadline {
                log.warning("CH343 fragment timed out on channel \(lastChannel.rawValue) after \(retryCount) retries, pending \(wire.remaining) bytes")
                return
            }
            if deadline != nil, now >= retryAt, wire.isEmpty {
                wire = OutputBuffer(inFlight)
                retryAt = now + retryInterval
                retryCount += 1
            }
            if deadline == nil {
                // Alternate under load. An input packet waits for at most one layout fragment.
                let useAnimation = animation?.fragment != nil && (control.fragment == nil || lastChannel == .layout)
                if let fragment = useAnimation ? animation?.fragment : control.fragment {
                    lastChannel = useAnimation ? .animation : .layout
                    if useAnimation { animation?.fragment = nil }
                    else { control.fragment = nil }
                    token &+= 1
                    inFlight = frame(lastChannel, token: token, payload: fragment)
                    wire = OutputBuffer(inFlight)
                    deadline = now + 2
                    // Opening can race the firmware boot. Retrying an ordinary fragment
                    // uses the same token so the board can acknowledge it without replaying it.
                    retryInterval = fragment.isEmpty ? 0.25 : 0.075
                    retryAt = now + retryInterval
                    retryCount = 0
                }
            }

            // Nonblocking serial writes may accept a short fragment before the
            // driver's write low-water mark reports POLLOUT. Try first and only
            // wait for capacity when there really are bytes left to write.
            if !wire.flush(to: serial) { return }
            var descriptors = [pollfd(fd: serial, events: Int16(POLLIN | (wire.isEmpty ? 0 : POLLOUT)), revents: 0),
                               pollfd(fd: listener, events: Int16(POLLIN), revents: 0), control.pollFD,
                               animation?.pollFD ?? pollfd(fd: -1, events: 0, revents: 0)]
            let ready = HardwareIO.wait(&descriptors, milliseconds: 50)
            let waited = ProcessInfo.processInfo.systemUptime - now
            if waited > 0.25 {
                log.warning("CH343 relay scheduling gap: \(waited) seconds, wait result \(ready)")
            }
            if ready < 0 { if errno == EINTR { continue }; return }
            if ready == 0 { continue }
            let serialEvents = descriptors[0].revents
            guard serialEvents & disconnected == 0, control.service(descriptors[2].revents) else { return }
            if let fd = animation?.fd, animation?.service(descriptors[3].revents) == false {
                close(fd)
                animation = nil
            }
            if descriptors[1].revents & Int16(POLLIN) != 0, let peer = acceptAnimation(listener) {
                if animation == nil { animation = peer }
                else { close(peer.fd) }
            }
            if serialEvents & Int16(POLLOUT) != 0, !wire.flush(to: serial) { return }
            if serialEvents & Int16(POLLIN) != 0 {
                let count = Darwin.read(serial, &buffer, buffer.count)
                if count < 0, !wouldBlock { return }
                guard count > 0 else { continue }
                for packet in decoder.feed(buffer.prefix(count)) {
                    switch packet.channel {
                    case .credit:
                        if packet.token == token, packet.payload.isEmpty {
                            if deadline != nil, retryCount > 0 {
                                log.info("CH343 fragment recovered after \(retryCount) retries on channel \(lastChannel.rawValue)")
                            }
                            deadline = nil
                            wire = OutputBuffer()
                            inFlight = Data()
                        }
                    case .layout:
                        if !control.appendReply(packet.payload) { return }
                    case .animation:
                        if let fd = animation?.fd, animation?.appendReply(packet.payload) == false {
                            close(fd)
                            animation = nil
                        }
                    }
                }
            }
        }
    }
}
