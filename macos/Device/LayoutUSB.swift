import Darwin
import Foundation
import MiucsCore
import IOKit
import IOKit.serial
import OSLog

enum LayoutUSBError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

actor LayoutUSB {
    private struct Endpoint: Equatable {
        let path: String
        let registryID: UInt64
        let usesUART: Bool
    }

    private struct SentContent: Equatable {
        let kind: UInt8
        let width: Int
        let height: Int
        let data: Data
        var expiresAt: Date?
    }

    private struct WidgetPacket<State: Encodable>: Encodable {
        let v = 1
        let data: State
        let after: State?
        var expiresInMs: Int?
    }

    private enum ContentResult {
        case unchanged, accepted, rejected(UInt8)
    }

    private struct WallpaperStatus {
        let limit: Int
        var length: Int
        var checksum: UInt32
        var supportsLandscape = false

        init?(line: String, sequence: UInt32) {
            guard line.hasPrefix("DESKISLE_WALLPAPER ") else { return nil }
            let fields = line.split(separator: " ")
            guard fields.count == 6, fields[1] == "1", UInt32(fields[2]) == sequence,
                  let limit = Int(fields[3]), limit >= 4,
                  let length = Int(fields[4]), (0...limit).contains(length),
                  let checksum = UInt32(fields[5]) else { return nil }
            self.limit = limit
            self.length = length
            self.checksum = checksum
        }
    }

    private static let jpegFrameKind: UInt8 = 1
    private static let alphaFrameKind: UInt8 = 5
    private static let widgetKind: UInt8 = 6
    private static let wallpaperKind: UInt8 = 7
    private static let glyphWidgetKind: UInt8 = 12
    private static let backlightKind: UInt8 = 13
    private static let maxWidgetBytes = 4096
    private static let maxGlyphPacketBytes = 256 * 1024
    private var sequence = UInt32.random(in: 0...UInt32.max)
    private var connection: (endpoint: Endpoint, port: SerialPort)?
    private var petChannel: UARTBridge.AnimationChannel?
    private var lastUpdates: [Int: SentContent] = [:]
    private var widgetVersion = 0
    private var supportsPictureAlpha = false
    private var glyphPacketLimit: Int?
    private let widgetFont = WidgetGlyphRasterizer()
    private var wallpaperStatus: WallpaperStatus?
    private var modelStatus: (limit: Int, chunk: Int, size: Int, crc: UInt32)?
    private var backlight: ScreenBacklight?
    private let widgetLog = Logger(subsystem: "com.deskisle.layout", category: "widgets")
    private let wallpaperLog = Logger(subsystem: "com.deskisle.layout", category: "wallpaper")
    private let connectionLog = Logger(subsystem: "com.deskisle.layout", category: "connection")
    private let displayLog = Logger(subsystem: "com.deskisle.layout", category: "display")

    /// The embedded Miucs runtime receives its own logical channel; this actor owns device discovery.
    func openPetChannel() throws -> Int32 {
        if connection == nil { _ = try readLayout() }
        guard let connection else { throw LayoutUSBError.message("等待连接小屏") }
        if connection.endpoint.usesUART {
            guard let petChannel else { throw LayoutUSBError.message("小屏通道尚未就绪") }
            return try petChannel.open()
        }
        guard let endpoint = try Self.controlPort(animation: true) else {
            throw LayoutUSBError.message("没有找到小屏桌宠接口")
        }
        return try SerialPort(path: endpoint.path).takeDescriptor()
    }

    func readLayout() throws -> LayoutReply? {
        try withControlPort(discover: true) { port in
            let reply = try exchange(port, kind: 3)
            checkLastUpdates(in: reply.layout)
            return reply
        }
    }

    func apply(_ layout: ScreenLayout) throws -> LayoutReply {
        guard layout.isValid else { throw LayoutUSBError.message("布局超出了小屏支持的范围。") }
        let result = try withControlPort(discover: true) { port in
            let current = try exchange(port, kind: 3)
            checkLastUpdates(in: current.layout)
            guard current.layout.panel == layout.panel else { throw LayoutUSBError.message("小屏规格已变化，请重新读取布局。") }
            if current.widgetVersion < 2, layout.macLoad != nil {
                throw LayoutUSBError.message("请更新小屏固件以显示 Mac 负载。")
            }
            if layout.model3D != nil, modelStatus == nil { throw LayoutUSBError.message("请更新小屏固件以显示 3D 模型。") }
            let reply = try exchange(port, kind: 4, payload: layout.encoded())
            checkLastUpdates(in: reply.layout)
            return reply
        }
        guard let result else { throw LayoutUSBError.message("桌屿已断开。") }
        return result
    }

    func setBacklight(_ requested: ScreenBacklight) throws {
        guard (0...100).contains(requested.brightness) else { throw LayoutUSBError.message("亮度须在 0% 至 100% 之间。") }
        guard let backlight else { throw LayoutUSBError.message("小屏暂时无法调节亮度。") }
        guard backlight != requested else { return }
        let status = try withControlPort { port in
            let payload = Data([UInt8(requested.brightness), requested.blanked ? 1 : 0])
            let (sequence, deadline) = try send(port, kind: Self.backlightKind, payload: payload)
            return try readStatus(port, sequence: sequence, deadline: deadline)
        }
        guard status == 0 else { throw LayoutUSBError.message("小屏亮度未能更新，稍后重试。") }
        self.backlight = requested
        displayLog.info("Screen accepted backlight brightness=\(requested.brightness) blanked=\(requested.blanked)")
    }

    @discardableResult
    func showFrame(_ jpeg: Data, alphaMask: Data? = nil, for component: Component, maxJPEG: Int) throws -> Bool {
        guard (2...Int(UInt16.max)).contains(component.id), !jpeg.isEmpty, jpeg.count <= maxJPEG else {
            throw LayoutUSBError.message("组件画面超过小屏支持的范围。")
        }
        var payload = jpeg
        var kind = Self.jpegFrameKind
        if supportsPictureAlpha, let alphaMask {
            guard component.isPicture, !alphaMask.isEmpty, alphaMask.count <= component.jpegPixels else {
                throw LayoutUSBError.message("图片透明度数据超出了组件尺寸。")
            }
            kind = Self.alphaFrameKind
            payload.append(alphaMask)
            withUnsafeBytes(of: UInt32(jpeg.count).littleEndian) { payload.append(contentsOf: $0) }
        }
        let content = SentContent(kind: kind, width: component.width, height: component.height, data: payload)
        return try sendContent(content, payload: payload, for: component)
    }

    func showWidget<State: WidgetGlyphSource>(_ state: State, for component: Component,
                                                expiresAt: Date? = nil, after: State? = nil) throws {
        let requiredVersion = component.isMacLoad ? 2 : 1
        guard widgetVersion >= requiredVersion else { throw LayoutUSBError.message("请更新小屏固件以显示组件数据。") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var packet = WidgetPacket(data: state, after: after)
        let stableData = try encoder.encode(packet)
        let content = SentContent(kind: Self.widgetKind, width: component.width, height: component.height,
                                  data: stableData, expiresAt: expiresAt)
        let payload: Data
        if let expiresAt {
            packet.expiresInMs = Int(min(60_000, max(0, ceil(expiresAt.timeIntervalSinceNow * 1_000))))
            payload = try encoder.encode(packet)
        } else {
            payload = stableData
        }
        guard payload.count <= Self.maxWidgetBytes else { throw LayoutUSBError.message("组件数据超过小屏支持的范围。") }
        if try sendContent(content, payload: payload, for: component, glyphRuns: state.glyphRuns + (after?.glyphRuns ?? [])) {
            widgetLog.info("Screen accepted widget data (\(component.id), \(payload.count) bytes)")
        }
    }

    func showWallpaper(_ image: WallpaperFrame, for panel: Panel) throws -> Bool {
        guard let current = wallpaperStatus else { return false }
        let upload = image.upload(supportsLandscape: current.supportsLandscape, limit: current.limit)
        guard current.length != upload.jpeg.count || current.checksum != upload.checksum else { return true }
        let status = try withControlPort { port -> UInt8 in
            guard var current = wallpaperStatus else { throw LayoutUSBError.message("小屏已断开。") }
            guard (4...current.limit).contains(upload.jpeg.count) else {
                throw LayoutUSBError.message("壁纸 JPEG 超出了小屏支持的大小。")
            }
            let width = upload.landscape ? panel.nativeHeight : panel.nativeWidth
            let height = upload.landscape ? panel.nativeWidth : panel.nativeHeight
            let started = ProcessInfo.processInfo.systemUptime
            let (sequence, deadline) = try send(port, kind: Self.wallpaperKind, payload: upload.jpeg,
                                                width: width, height: height, timeout: 8)
            let status = try readStatus(port, sequence: sequence, deadline: deadline)
            if status == 0 {
                current.length = upload.jpeg.count
                current.checksum = upload.checksum
                wallpaperStatus = current
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                wallpaperLog.info("Screen accepted wallpaper (\(width)x\(height), \(upload.jpeg.count) bytes, \(elapsed) ms)")
            }
            return status
        }
        guard let status else { throw LayoutUSBError.message("桌屿已断开。") }
        guard status == 0 else { throw LayoutUSBError.message("壁纸上传失败，稍后重试。") }
        return true
    }

    private func sendContent(_ content: SentContent, payload: Data, for component: Component,
                             glyphRuns: [WidgetGlyphRun] = []) throws -> Bool {
        let result = try withControlPort { port -> ContentResult in
            if content.kind == Self.widgetKind, widgetVersion == 0 {
                throw LayoutUSBError.message("请更新小屏固件以显示组件数据。")
            }
            if lastUpdates[component.id] == content { return .unchanged }
            let jpeg = content.kind == Self.jpegFrameKind || content.kind == Self.alphaFrameKind
            let glyphPacket = glyphPacketLimit.flatMap { widgetFont.packet(json: payload, runs: glyphRuns, limit: $0) }
            let kind = glyphPacket == nil ? content.kind : Self.glyphWidgetKind
            let (sequence, deadline) = try send(port, kind: kind, payload: glyphPacket ?? payload, id: component.id,
                                                width: jpeg ? component.jpegWidth : 0,
                                                height: jpeg ? component.jpegHeight : 0,
                                                timeout: glyphPacket == nil ? 3 : 8)
            let status = try readStatus(port, sequence: sequence, deadline: deadline)
            guard status == 0 else { return .rejected(status) }
            lastUpdates[component.id] = content
            return .accepted
        }
        guard let result else { throw LayoutUSBError.message("桌屿已断开。") }
        switch result {
        case .unchanged: return false
        case .accepted: return true
        case .rejected(4): throw LayoutUSBError.message("小屏拒绝了组件数据。")
        case .rejected: throw LayoutUSBError.message("小屏未能显示组件。")
        }
    }

    private func readStatus(_ port: SerialPort, sequence: UInt32, deadline: Double) throws -> UInt8 {
        while true {
            let fields = try port.readLine(deadline: deadline).split(separator: " ")
            guard fields.count == 4, fields[0] == "DESKISLE_ACK", UInt32(fields[1]) == sequence,
                  let status = UInt8(fields[2]) else { continue }
            return status
        }
    }

    func showModel3D(_ pack: Data,scale: Int) throws {
        guard let capability=modelStatus,pack.count >= 20,pack.count <= capability.limit,[1,2,4].contains(scale) else {
            throw LayoutUSBError.message("模型超出支持范围，或小屏尚未支持 3D。")
        }
        let checksum=Self.crc32(pack)
        let sent = try withControlPort { port -> Bool in
            func request(_ kind: UInt8,_ payload: Data) throws {
                if Task.isCancelled { throw CancellationError() }
                let (sequence,deadline)=try send(port,kind:kind,payload:payload,id:Component.model3DID,timeout:15)
                guard try readStatus(port,sequence:sequence,deadline:deadline)==0 else { throw LayoutUSBError.message("小屏未能接收 3D 模型，请检查资源或重试。") }
            }
            if capability.size != pack.count || capability.crc != checksum {
                var begin=Data()
                for v in [UInt32(pack.count),checksum] { withUnsafeBytes(of:v.littleEndian){ begin.append(contentsOf:$0) } }
                do {
                    try request(16,begin)
                    for offset in stride(from:0,to:pack.count,by:capability.chunk) {
                        var chunk=Data();withUnsafeBytes(of:UInt32(offset).littleEndian){chunk.append(contentsOf:$0)}
                        chunk.append(pack.subdata(in:offset..<min(pack.count,offset+capability.chunk)))
                        try request(17,chunk)
                    }
                    try request(18,Data())
                    modelStatus=(capability.limit,capability.chunk,pack.count,checksum)
                } catch {
                    // Best-effort release of partial PSRAM uploads. The board also has a 30 s timeout.
                    if let (seq,deadline)=try? send(port,kind:21,payload:Data(),id:Component.model3DID,timeout:2) {
                        _ = try? readStatus(port,sequence:seq,deadline:deadline)
                    }
                    throw error
                }
            }
            try request(19,Data([2,UInt8(scale)]))
            return true
        }
        guard sent == true else { throw LayoutUSBError.message("桌屿已断开。") }
    }

    func model3DControl(_ action: UInt8,value: UInt8 = 0) throws {
        let status=try withControlPort { port in
            let (seq,deadline)=try send(port,kind:19,payload:Data([action,value]),id:Component.model3DID,timeout:15)
            return try readStatus(port,sequence:seq,deadline:deadline)
        }
        guard status == 0 else { throw LayoutUSBError.message("无法控制小屏 3D 动画。") }
    }

    func model3DStatistics() throws -> Model3DStats {
        let result=try withControlPort { port -> Model3DStats in
            let (seq,deadline)=try send(port,kind:20,payload:Data(),id:Component.model3DID,timeout:15)
            var stats: Model3DStats?
            while true {
                let line=try port.readLine(deadline:deadline)
                if let value=Model3DStats(line:line,sequence:seq){stats=value}
                let f=line.split(separator:" ")
                if f.count==4,f[0]=="DESKISLE_ACK",UInt32(f[1])==seq {
                    guard f[2]=="0",let stats else { throw LayoutUSBError.message("小屏未返回 3D 性能数据。") }
                    return stats
                }
            }
        }
        guard let result else { throw LayoutUSBError.message("桌屿已断开。") };return result
    }

    private func withControlPort<Result>(discover: Bool = false,
                                         _ use: (SerialPort) throws -> Result) throws -> Result? {
        do {
            if !discover, let connection { return try use(connection.port) }
            let endpoint = try Self.controlPort()
            if endpoint != connection?.endpoint {
                resetConnection()
            }
            guard let endpoint else { return nil }
            let port: SerialPort
            if let current = connection?.port {
                port = current
            } else if endpoint.usesUART {
                guard let relay = try UARTBridge.start(serialPath: endpoint.path) else { return nil }
                port = SerialPort(relay: relay.layout)
                petChannel = relay.animation
            } else {
                // Keep CDC open across requests so sending frames does not repeatedly toggle DTR.
                port = try SerialPort(path: endpoint.path)
            }
            connection = (endpoint, port)
            return try use(port)
        } catch {
            if connection?.endpoint.usesUART == true {
                connectionLog.info("CH343 session ended: \(error.localizedDescription, privacy: .public)")
            }
            resetConnection()
            throw error
        }
    }

    private func resetConnection() {
        connection = nil
        petChannel = nil
        lastUpdates.removeAll()
        widgetVersion = 0
        supportsPictureAlpha = false
        glyphPacketLimit = nil
        wallpaperStatus = nil
        modelStatus = nil
        backlight = nil
    }

    private func checkLastUpdates(in layout: ScreenLayout) {
        lastUpdates = lastUpdates.filter { id, update in
            layout.components.contains {
                $0.id == id && $0.width == update.width && $0.height == update.height
            }
        }
    }

    private func exchange(_ port: SerialPort, kind: UInt8, payload: Data = Data()) throws -> LayoutReply {
        let (sequence, deadline) = try send(port, kind: kind, payload: payload)
        var widgetVersion = 0
        var glyphPacketLimit: Int?
        var wallpaperStatus: WallpaperStatus?
        var supportsLandscapeWallpaper = false
        var supportsPictureAlpha = false
        var backlight: ScreenBacklight?
        var modelStatus: (limit: Int,chunk: Int,size: Int,crc: UInt32)?
        while true {
            let line = try port.readLine(deadline: deadline)
            if line == "DESKISLE_WIDGETS 1 \(sequence)" { widgetVersion = max(widgetVersion, 1) }
            if line == "DESKISLE_WIDGETS 2 \(sequence)" { widgetVersion = 2 }
            if line == "DESKISLE_WIDGETS 3 \(sequence)" { widgetVersion = 3 }
            if line.hasPrefix("DESKISLE_3D ") {
                let f=line.split(separator:" ")
                if f.count==7,f[1]=="1",UInt32(f[2])==sequence,let limit=Int(f[3]),(20...Model3DImporter.maxPack).contains(limit),
                   let chunk=Int(f[4]),(256...32768).contains(chunk),let size=Int(f[5]),(0...limit).contains(size),let crc=UInt32(f[6]) {
                    modelStatus=(limit,chunk,size,crc)
                }
            }
            if line.hasPrefix("DESKISLE_GLYPHS ") {
                let fields = line.split(separator: " ")
                if fields.count == 4, fields[1] == "1", UInt32(fields[2]) == sequence,
                   let limit = Int(fields[3]), limit >= 6 {
                    glyphPacketLimit = min(limit, Self.maxGlyphPacketBytes)
                }
            }
            if let status = WallpaperStatus(line: line, sequence: sequence) { wallpaperStatus = status }
            if line == "DESKISLE_WALLPAPER_LANDSCAPE 1 \(sequence)" { supportsLandscapeWallpaper = true }
            if line == "DESKISLE_PICTURE_ALPHA 1 \(sequence)" { supportsPictureAlpha = true }
            if let state = ScreenBacklight(line: line, sequence: sequence) { backlight = state }
            if let reply = LayoutReply(line: line, sequence: sequence, backlight: backlight, widgetVersion: widgetVersion,
                                       modelResident:(modelStatus?.size ?? 0)>0) {
                self.widgetVersion = widgetVersion
                self.supportsPictureAlpha = supportsPictureAlpha
                self.glyphPacketLimit = glyphPacketLimit
                wallpaperStatus?.supportsLandscape = supportsLandscapeWallpaper
                self.wallpaperStatus = wallpaperStatus
                self.modelStatus = modelStatus
                self.backlight = backlight
                return reply
            }
        }
    }

    private func send(_ port: SerialPort, kind: UInt8, payload: Data,
                      id: Int = 0, width: Int = 0, height: Int = 0, timeout: TimeInterval = 3) throws -> (UInt32, Double) {
        sequence &+= 1
        var bytes = Data("ISLE".utf8)
        bytes.append(contentsOf: [1, kind])
        withUnsafeBytes(of: UInt16(id).littleEndian) { bytes.append(contentsOf: $0) }
        for value in [sequence, UInt32(payload.count), Self.crc32(payload)] {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        for value in [width, height] {
            withUnsafeBytes(of: UInt16(value).littleEndian) { bytes.append(contentsOf: $0) }
        }
        bytes.append(payload)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try port.write(bytes, deadline: deadline)
        return (sequence, deadline)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
        }
        return ~crc
    }

    private static func controlPort(animation: Bool = false) throws -> Endpoint? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &iterator)
                == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var endpoints = [Endpoint]()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func parentProperty(_ key: String) -> CFTypeRef? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            let product = parentProperty("USB Product Name") as? String
            let usesUART: Bool
            if product == "DeskIsle" {
                let name = parentProperty("USB Interface Name") as? String
                let interface = (parentProperty("bInterfaceNumber") as? NSNumber)?.intValue
                let layout = name == "DeskIsle Layout" || interface == 2 || interface == 3
                guard animation ? !layout : layout else { continue }
                usesUART = false
            } else {
                guard !animation else { continue }
                let vendor = (parentProperty("idVendor") as? NSNumber)?.intValue
                let device = (parentProperty("idProduct") as? NSNumber)?.intValue
                guard product == "USB Single Serial", vendor == 0x1a86, device == 0x55d3 else { continue }
                usesUART = true
            }
            var registryID: UInt64 = 0
            if let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString,
                                                           kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS {
                endpoints.append(Endpoint(path: path, registryID: registryID, usesUART: usesUART))
            }
        }
        let native = endpoints.filter { !$0.usesUART }
        let candidates = native.isEmpty ? endpoints : native
        guard candidates.count <= 1 else { throw LayoutUSBError.message("检测到多个小屏端口，请只连接需要设置的小屏。") }
        return candidates.first
    }
}

private final class SerialPort {
    private var fd: Int32
    private var input = Data()

    init(relay: Int32) { fd = relay }

    init(path: String) throws {
        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw LayoutUSBError.message("无法打开桌屿的布局接口。") }
        var config = termios()
        guard ioctl(descriptor, TIOCEXCL) == 0, tcgetattr(descriptor, &config) == 0 else {
            Darwin.close(descriptor)
            throw LayoutUSBError.message("桌屿的布局接口正在使用。")
        }
        cfmakeraw(&config)
        config.c_cflag |= tcflag_t(CLOCAL | CREAD)
        config.c_cflag &= ~tcflag_t(HUPCL)
        cfsetspeed(&config, speed_t(B115200))
        guard tcsetattr(descriptor, TCSANOW, &config) == 0 else {
            Darwin.close(descriptor)
            throw LayoutUSBError.message("无法配置桌屿的布局接口。")
        }
        fd = descriptor
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    func takeDescriptor() -> Int32 {
        defer { fd = -1 }
        return fd
    }

    func write(_ data: Data, deadline: Double) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(POLLOUT, deadline: deadline)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0 && errno != EAGAIN && errno != EINTR {
                    throw LayoutUSBError.message("USB 发送中断。")
                }
            }
        }
    }

    func readLine(deadline: Double) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            if let end = input.firstIndex(of: 10) {
                let line = String(decoding: input[..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                input.removeSubrange(...end)
                return line
            }
            try wait(POLLIN, deadline: deadline)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                input.append(contentsOf: buffer.prefix(count))
                if input.count > 4096 { throw LayoutUSBError.message("桌屿返回了无法识别的布局。") }
            } else if count < 0 && errno != EAGAIN && errno != EINTR {
                throw LayoutUSBError.message("USB 读取中断。")
            }
        }
    }

    private func wait(_ events: Int32, deadline: Double) throws {
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            var descriptors = [pollfd(fd: fd, events: Int16(events), revents: 0)]
            let result = HardwareIO.wait(&descriptors, milliseconds: 40)
            if result < 0 && errno != EINTR { throw LayoutUSBError.message("USB 连接错误。") }
            if result > 0 {
                if descriptors[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    throw LayoutUSBError.message("桌屿已断开。")
                }
                if descriptors[0].revents & Int16(events) != 0 { return }
            }
        }
        throw LayoutUSBError.message("小屏没有回应，请检查连接。")
    }
}
