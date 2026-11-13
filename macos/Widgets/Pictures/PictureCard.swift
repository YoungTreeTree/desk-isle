import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum PictureError: String, LocalizedError {
    case unreadable = "无法读取这张图片。"
    case fileTooLarge = "请选择 32 MB 以内的图片。"
    case animationTooLarge = "这张 GIF 的帧数或画面尺寸太大。"
    case encodingFailed = "无法生成小屏可显示的图片。"
    case storageFailed = "无法将图片保存到本机。"
    case noRoom = "当前布局无法再添加图片组件。"

    var errorDescription: String? { rawValue }
}

struct PictureFile: Codable, Sendable {
    private static let maxBytes = 32 * 1024 * 1024

    let name: String
    let data: Data

    init(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw PictureError.unreadable }
        guard (values.fileSize ?? 0) <= Self.maxBytes else { throw PictureError.fileTooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maxBytes else { throw PictureError.fileTooLarge }
        self.name = url.lastPathComponent
        self.data = data
    }

    func save(for id: Int) throws {
        do {
            let url = try Self.url(for: id)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            throw PictureError.storageFailed
        }
    }

    static func load(for id: Int) throws -> PictureFile {
        let data = try Data(contentsOf: url(for: id))
        let file = try PropertyListDecoder().decode(Self.self, from: data)
        guard file.data.count <= maxBytes else { throw PictureError.fileTooLarge }
        return file
    }

    private static func url(for id: Int) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false)
        return support.appending(path: "com.deskisle.layout/Pictures", directoryHint: .isDirectory)
            .appending(path: "\(id).plist", directoryHint: .notDirectory)
    }
}

struct PictureFrameImage: Sendable {
    let jpeg: Data
    let alphaMask: Data?
}

struct PictureAsset: Sendable {
    private struct Frame: Sendable {
        let start: TimeInterval
        let images: [Int: PictureFrameImage]
    }

    static let frameInterval = 0.125
    static let previewBudget = 24 * 1024 * 1024
    private static let maxPreparedFrames = 144
    private static let transparentBitmap = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    private static let opaqueBitmap = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue

    let id = UUID()
    let name: String
    let poster: CGImage
    private let frames: [Frame]
    private let duration: TimeInterval
    private let startedAt = ProcessInfo.processInfo.systemUptime

    var isAnimated: Bool { frames.count > 1 }

    func image(at time: TimeInterval, side: Int) -> PictureFrameImage? {
        frames[frameIndex(at: time)].images[side]
    }

    func frameIndex(at time: TimeInterval) -> Int {
        guard isAnimated else { return 0 }
        let elapsed = max(0, time - startedAt).truncatingRemainder(dividingBy: duration)
        return frames.lastIndex { $0.start <= elapsed } ?? 0
    }

    func decodePreview(side: Int, byteLimit: Int) -> [CGImage]? {
        // Cache an entire loop at a size that fits, so long GIFs do not
        // repeatedly decode frames evicted by the previous loop.
        let maxSide = Int(sqrt(Double(byteLimit / (4 * frames.count))))
        let length = min(side, maxSide) / 16 * 16
        guard length > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bounds = CGRect(x: 0, y: 0, width: length, height: length)
        var images = [CGImage]()
        images.reserveCapacity(frames.count)
        for frame in frames {
            guard !Task.isCancelled else { return nil }
            let bitmap: CGImage? = autoreleasepool {
                guard let encoded = frame.images[side],
                      let image = decodeImage(encoded, side: side, colorSpace: colorSpace),
                      let context = CGContext(data: nil, width: length, height: length, bitsPerComponent: 8,
                                              bytesPerRow: length * 4, space: colorSpace,
                                              bitmapInfo: encoded.alphaMask == nil ? Self.opaqueBitmap : Self.transparentBitmap)
                else { return nil }
                context.interpolationQuality = .high
                context.setBlendMode(.copy)
                context.draw(image, in: bounds)
                return context.makeImage()
            }
            guard let bitmap else { return nil }
            images.append(bitmap)
        }
        return images
    }

    static func prepare(_ file: PictureFile) throws -> PictureAsset {
        guard let source = CGImageSourceCreateWithData(file.data as CFData, nil),
              let type = CGImageSourceGetType(source), let imageType = UTType(type as String),
              imageType.conforms(to: .image), CGImageSourceGetCount(source) > 0 else { throw PictureError.unreadable }

        let count = imageType == .gif ? CGImageSourceGetCount(source) : 1
        let sides = GridSize.pictureSizes.map(\.width)
        let largest = sides.max() ?? 320
        var starts: [TimeInterval] = [0]
        if count > 1 {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            guard count <= 1_200, width > 0, height > 0, width <= 8_500_000 / height else {
                throw PictureError.animationTooLarge
            }
            for index in 0..<count {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                    ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
                starts.append(starts[index] + (delay.isFinite && delay >= 0.02 ? delay : 0.1))
            }
        }

        let sourceDuration = starts[count > 1 ? count : 0]
        let duration = count > 1 ? max(sourceDuration, 2 * frameInterval) : 0
        let timeScale = count > 1 ? duration / sourceDuration : 1
        let interval = max(frameInterval, duration / Double(maxPreparedFrames - 1))
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: largest,
        ] as CFDictionary
        var poster: CGImage?
        var frames: [Frame] = []
        var nextFrame: TimeInterval = 0
        for index in 0..<count {
            try Task.checkCancellation()
            let start = starts[index] * timeScale
            let isLastOfShortGIF = count > 1 && index == count - 1 && frames.count == 1
            guard (start >= nextFrame - 0.000_001 || isLastOfShortGIF),
                  frames.count < maxPreparedFrames else { continue }
            let frame = try autoreleasepool {
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options)
                else { throw PictureError.unreadable }
                var encoded: [Int: PictureFrameImage] = [:]
                for side in sides {
                    let (square, frame) = try encodeFrame(image, side: side)
                    encoded[side] = frame
                    if side == largest && poster == nil { poster = square }
                }
                return Frame(start: isLastOfShortGIF ? min(start, duration - frameInterval) : start, images: encoded)
            }
            frames.append(frame)
            nextFrame = start + interval
        }
        guard let poster, !frames.isEmpty else { throw PictureError.unreadable }
        return PictureAsset(name: file.name, poster: poster, frames: frames, duration: duration)
    }

    private static func encodeFrame(_ image: CGImage, side: Int) throws -> (CGImage, PictureFrameImage) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let hasAlpha: Bool = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: colorSpace,
                                      bitmapInfo: hasAlpha ? transparentBitmap : opaqueBitmap) else {
            throw PictureError.encodingFailed
        }
        let length = CGFloat(side)
        let bounds = CGRect(x: 0, y: 0, width: length, height: length)
        if hasAlpha {
            context.clear(bounds)
        } else {
            context.setFillColor(gray: 0.08, alpha: 1)
            context.fill(bounds)
        }
        let scale = length / CGFloat(max(image.width, image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (length - width) / 2, y: (length - height) / 2, width: width, height: height))
        guard let square = context.makeImage(), let base = context.data else { throw PictureError.encodingFailed }
        let pixels = UnsafeRawBufferPointer(start: base, count: side * side * 4)
        let mask = hasAlpha ? packAlpha(pixels) : nil
        // Give JPEG the premultiplied color bytes and carry the coverage separately.
        let color = mask == nil ? square :
            bitmapImage(Data(pixels), side: side, colorSpace: colorSpace, info: opaqueBitmap)
        guard let color,
              let jpeg = encodeImageJPEG(color, maxBytes: Panel.deskIsle.maxJPEG, qualities: [0.84, 0.68, 0.50])
        else { throw PictureError.encodingFailed }
        return (square, PictureFrameImage(jpeg: jpeg, alphaMask: mask))
    }

    private static func packAlpha(_ pixels: UnsafeRawBufferPointer) -> Data? {
        var raw = Data(count: pixels.count / 4)
        let hasTransparency = raw.withUnsafeMutableBytes { (alpha: UnsafeMutableRawBufferPointer) in
            var transparent = false
            for index in 0..<alpha.count {
                let value = pixels[4 * index + 3]
                alpha[index] = value
                transparent = transparent || value < 255
            }
            return transparent
        }
        guard hasTransparency else { return nil }
        return raw.withUnsafeBytes { (alpha: UnsafeRawBufferPointer) in
            var runs = Data()
            var start = 0
            while start < alpha.count {
                let value = alpha[start]
                let limit = min(start + 255, alpha.count)
                var end = start + 1
                while end < limit && alpha[end] == value { end += 1 }
                if runs.count + 2 >= alpha.count { return raw }
                runs.append(UInt8(end - start))
                runs.append(value)
                start = end
            }
            return runs
        }
    }

    private static func unpackAlpha(_ mask: Data, count: Int) -> Data? {
        if mask.count == count { return mask }
        guard mask.count.isMultiple(of: 2) else { return nil }
        var raw = Data(capacity: count)
        var offset = mask.startIndex
        while offset < mask.endIndex {
            let run = Int(mask[offset])
            guard run > 0, run <= count - raw.count else { return nil }
            raw.append(contentsOf: repeatElement(mask[offset + 1], count: run))
            offset += 2
        }
        return raw.count == count ? raw : nil
    }

    private func decodeImage(_ frame: PictureFrameImage, side: Int, colorSpace: CGColorSpace) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(frame.jpeg as CFData, nil),
              let color = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        guard let mask = frame.alphaMask else { return color }
        guard let alpha = Self.unpackAlpha(mask, count: side * side),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: colorSpace, bitmapInfo: Self.opaqueBitmap),
              let base = context.data else { return nil }
        context.draw(color, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = UnsafeMutableRawBufferPointer(start: base, count: side * side * 4)
        for (index, value) in alpha.enumerated() {
            let offset = index * 4
            // Keep the decoded JPEG channels valid for premultiplied alpha.
            pixels[offset] = min(value, pixels[offset])
            pixels[offset + 1] = min(value, pixels[offset + 1])
            pixels[offset + 2] = min(value, pixels[offset + 2])
            pixels[offset + 3] = value
        }
        return Self.bitmapImage(Data(pixels), side: side, colorSpace: colorSpace, info: Self.transparentBitmap)
    }

    private static func bitmapImage(_ pixels: Data, side: Int, colorSpace: CGColorSpace, info: UInt32) -> CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

struct PictureCardPreview: View {
    let asset: PictureAsset?
    let side: Int
    let animationBytes: Int
    let isPlaying: Bool

    var body: some View {
        if let asset {
            if asset.isAnimated, animationBytes > 0 {
                AnimatedPicturePreview(asset: asset, side: side, byteLimit: animationBytes, isPlaying: isPlaying)
            } else {
                Image(decorative: asset.poster, scale: 1).resizable()
            }
        } else {
            Color(red: 0.15, green: 0.17, blue: 0.20)
                .overlay { Image(systemName: "photo").foregroundStyle(.white.opacity(0.7)) }
        }
    }
}

private struct AnimatedPicturePreview: View {
    private struct Request: Hashable {
        let assetID: UUID
        let side: Int
        let byteLimit: Int
    }

    let asset: PictureAsset
    let side: Int
    let byteLimit: Int
    let isPlaying: Bool
    @State private var prepared: (request: Request, images: [CGImage])?

    var body: some View {
        let request = Request(assetID: asset.id, side: side, byteLimit: byteLimit)
        Group {
            if let prepared, prepared.request == request {
                PictureFramePlayer(asset: asset, frames: prepared.images, isPlaying: isPlaying).id(request)
            } else {
                Image(decorative: asset.poster, scale: 1).resizable()
            }
        }
        .task(id: request) {
            prepared = nil
            let worker = Task.detached(priority: .utility) {
                asset.decodePreview(side: side, byteLimit: byteLimit)
            }
            let images = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            if !Task.isCancelled, let images { prepared = (request, images) }
        }
    }
}

private struct PictureFramePlayer: NSViewRepresentable {
    let asset: PictureAsset
    let frames: [CGImage]
    let isPlaying: Bool

    func makeNSView(context: Context) -> Player { Player(asset: asset, frames: frames) }
    func updateNSView(_ view: Player, context: Context) { view.setPlaying(isPlaying) }
    static func dismantleNSView(_ view: Player, coordinator: ()) { view.stop() }

    final class Player: NSView {
        private let asset: PictureAsset
        private let frames: [CGImage]
        private var isPlaying = false
        private var timer: Timer?
        private var frameIndex: Int?

        init(asset: PictureAsset, frames: [CGImage]) {
            self.asset = asset
            self.frames = frames
            super.init(frame: .zero)
            wantsLayer = true
            layer?.contentsGravity = .resize
            layer?.actions = ["contents": NSNull()]
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updatePlayback()
        }

        func setPlaying(_ value: Bool) {
            guard value != isPlaying else { return }
            isPlaying = value
            updatePlayback()
        }

        private func updatePlayback() {
            stop()
            guard window != nil else { return }
            if isPlaying || frameIndex == nil { showFrame() }
            guard isPlaying else { return }
            let timer = Timer(timeInterval: PictureAsset.frameInterval, repeats: true) { [weak self] timer in
                guard self != nil else { timer.invalidate(); return }
                MainActor.assumeIsolated { self?.showFrame() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func showFrame() {
            let index = asset.frameIndex(at: ProcessInfo.processInfo.systemUptime)
            guard index != frameIndex else { return }
            frameIndex = index
            // Updating contents leaves the surrounding SwiftUI layout untouched.
            layer?.contents = frames[index]
        }
    }
}
