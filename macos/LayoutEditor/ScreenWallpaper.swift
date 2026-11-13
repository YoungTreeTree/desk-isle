#if canImport(DeskIsleNative)
import DeskIsleNative
#endif
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum WallpaperError: String, LocalizedError {
    case unreadable = "无法读取这张壁纸。"
    case encodingFailed = "无法生成小屏可显示的壁纸。"
    case storageFailed = "无法将壁纸保存到本机。"

    var errorDescription: String? { rawValue }
}

struct WallpaperPayload: Sendable {
    let jpeg: Data
    let checksum: UInt32
    let landscape: Bool

    init(jpeg: Data, landscape: Bool) {
        self.jpeg = jpeg
        checksum = LayoutUSB.crc32(jpeg)
        self.landscape = landscape
    }
}

final class WallpaperFrame: Sendable {
    let image: CGImage
    private let payload: WallpaperPayload
    private let legacyPayload: WallpaperPayload?
    private let textures: WallpaperTextures

    @MainActor func frostedMaterial(at origin: CGPoint, size: CGSize) -> FrostedCardMaterial {
        textures.material(at: origin, size: size)
    }

    init?(jpeg: Data, landscape: Bool, nativeLandscape: Data? = nil) {
        guard let portrait = Self.decode(jpeg, landscape: false) else { return nil }
        let portraitPayload = WallpaperPayload(jpeg: jpeg, landscape: false)
        let source: CGImage
        let upload: WallpaperPayload
        if landscape, let nativeLandscape, let wide = Self.decode(nativeLandscape, landscape: true) {
            source = wide
            upload = WallpaperPayload(jpeg: nativeLandscape, landscape: true)
            legacyPayload = portraitPayload
        } else {
            source = portrait
            upload = portraitPayload
            legacyPayload = nil
        }
        guard let preview = landscape && !upload.landscape ? source.cropping(to: ScreenWallpaper.landscapeCrop) : source
        else { return nil }
        image = preview
        payload = upload
        textures = WallpaperTextures(native: source, landscape: landscape)
    }

    func upload(supportsLandscape: Bool, limit: Int) -> WallpaperPayload {
        if let legacyPayload, !supportsLandscape || payload.jpeg.count > limit { return legacyPayload }
        return payload
    }

    private static func decode(_ jpeg: Data, landscape: Bool) -> CGImage? {
        let width = landscape ? ScreenWallpaper.nativeHeight : ScreenWallpaper.nativeWidth
        let height = landscape ? ScreenWallpaper.nativeWidth : ScreenWallpaper.nativeHeight
        guard (4...ScreenWallpaper.maxJPEGBytes).contains(jpeg.count),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let type = CGImageSourceGetType(source), type as String == UTType.jpeg.identifier,
              let native = CGImageSourceCreateImageAtIndex(source, 0, nil),
              native.width == width, native.height == height else { return nil }
        return native
    }
}

@MainActor
private final class WallpaperTextures {
    let native: CGImage
    let landscape: Bool

    nonisolated init(native: CGImage, landscape: Bool) {
        self.native = native
        self.landscape = landscape
    }

    private lazy var grid = ScreenWallpaper.frostedGrid(native, landscape: landscape)
    private lazy var light = grid.flatMap { ScreenWallpaper.frostedTexture($0, landscape: landscape, dark: false) }
    private lazy var dark = grid.flatMap { ScreenWallpaper.frostedTexture($0, landscape: landscape, dark: true) }

    func material(at origin: CGPoint, size: CGSize) -> FrostedCardMaterial {
        guard let grid else { return FrostedCardMaterial() }
        let rect = desk_rect(x: UInt16(max(0, origin.x.rounded())), y: UInt16(max(0, origin.y.rounded())),
                             width: UInt16(size.width), height: UInt16(size.height))
        let useDark = grid.withUnsafeBufferPointer {
            desk_frost_is_dark($0.baseAddress, rect, landscape ? 3 : 0)
        }
        return FrostedCardMaterial(texture: useDark ? dark : light, dark: useDark)
    }
}

struct ScreenWallpaper: Sendable {
    static let nativeWidth = Int(DESK_LCD_WIDTH)
    static let nativeHeight = Int(DESK_LCD_HEIGHT)
    static let maxJPEGBytes = 512 * 1024

    // Match the center band used by desk_layout_draw_wallpaper in landscape.
    static let landscapeCrop: CGRect = {
        let height = nativeWidth * nativeWidth / nativeHeight
        return CGRect(x: 0, y: (nativeHeight - height) / 2, width: nativeWidth, height: height)
    }()

    let name: String?
    let portrait: WallpaperFrame?
    let landscape: WallpaperFrame?

    var title: String { name ?? "默认壁纸" }
    var isCustom: Bool { name != nil }

    func frame(for direction: ScreenDirection) -> WallpaperFrame? {
        direction.isLandscape ? landscape : portrait
    }

    static var bundled: ScreenWallpaper {
        let jpeg = Bundle.main.url(forResource: "wallpaper", withExtension: "jpg").flatMap { try? Data(contentsOf: $0) }
        return ScreenWallpaper(name: nil,
                               portrait: jpeg.flatMap { WallpaperFrame(jpeg: $0, landscape: false) },
                               landscape: jpeg.flatMap { WallpaperFrame(jpeg: $0, landscape: true) })
    }

    fileprivate static func frostedGrid(_ image: CGImage, landscape: Bool) -> [UInt32]? {
        let sourceLandscape = image.width == nativeHeight && image.height == nativeWidth
        guard sourceLandscape || (image.width == nativeWidth && image.height == nativeHeight),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let count = image.width * image.height
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        var rgba = [UInt8](repeating: 0, count: count * 4)
        let decoded = rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: colorSpace, bitmapInfo: bitmapInfo) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard decoded else { return nil }
        var wallpaper = [UInt16](repeating: 0, count: count)
        for i in 0..<count {
            let r = UInt16(rgba[i * 4]), g = UInt16(rgba[i * 4 + 1]), b = UInt16(rgba[i * 4 + 2])
            wallpaper[i] = (r & 248) << 8 | (g & 252) << 3 | b >> 3
        }

        let rotation: UInt8 = landscape ? 3 : 0
        var grid = [UInt32](repeating: 0, count: Int(DESK_FROST_SAMPLES))
        if landscape {
            var oriented = [UInt16](repeating: 0, count: count)
            desk_layout_draw_wallpaper(&oriented, wallpaper, rotation, sourceLandscape)
            desk_frost_prepare(&grid, oriented, rotation)
        } else {
            desk_frost_prepare(&grid, wallpaper, rotation)
        }
        return grid
    }

    fileprivate static func frostedTexture(_ grid: [UInt32], landscape: Bool, dark: Bool) -> CGImage? {
        let width = (landscape ? nativeHeight : nativeWidth) / Int(DESK_FROST_STEP)
        let height = (landscape ? nativeWidth : nativeHeight) / Int(DESK_FROST_STEP)
        // Scale the cached 8 px samples in SwiftUI. Dragging only moves the crop.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        grid.withUnsafeBufferPointer { samples in
            let colors = desk_frost_colors(samples.baseAddress, dark)!
            for i in 0..<(width * height) {
                let color = colors[i]
                rgba[i * 4] = UInt8(truncatingIfNeeded: color >> 16)
                rgba[i * 4 + 1] = UInt8(truncatingIfNeeded: color >> 8)
                rgba[i * 4 + 2] = UInt8(truncatingIfNeeded: color)
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func fitted(_ image: CGImage, in size: CGSize) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    static func portion(_ image: CGImage, size: CGSize, screenSize: CGSize, origin: CGPoint) -> some View {
        fitted(image, in: screenSize)
            .offset(x: -origin.x, y: -origin.y)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
    }
}

struct SavedWallpaper: Codable {
    let name: String
    let portrait: Data
    let landscape: Data
    let nativeLandscape: Data?

    func makeWallpaper() throws -> ScreenWallpaper {
        guard let portrait = WallpaperFrame(jpeg: portrait, landscape: false),
              let landscape = WallpaperFrame(jpeg: landscape, landscape: true, nativeLandscape: nativeLandscape) else {
            throw WallpaperError.unreadable
        }
        return ScreenWallpaper(name: name, portrait: portrait, landscape: landscape)
    }
}

struct WallpaperStore: Sendable {
    let url: URL

    static func local() throws -> Self {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false)
        return Self(url: support.appending(path: "com.deskisle.layout", directoryHint: .isDirectory)
            .appending(path: "Wallpaper.plist", directoryHint: .notDirectory))
    }

    func load() -> ScreenWallpaper {
        guard let bytes = try? Data(contentsOf: url),
              let saved = try? PropertyListDecoder().decode(SavedWallpaper.self, from: bytes),
              let wallpaper = try? saved.makeWallpaper() else { return .bundled }
        return wallpaper
    }

    func loadRequired() throws -> ScreenWallpaper {
        try PropertyListDecoder().decode(SavedWallpaper.self, from: Data(contentsOf: url)).makeWallpaper()
    }

    func importImage(from sourceURL: URL) throws -> ScreenWallpaper {
        try importImage(PictureFile(from: sourceURL))
    }

    func importImage(_ file: PictureFile) throws -> ScreenWallpaper {
        guard let source = CGImageSourceCreateWithData(file.data as CFData, nil),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2560,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw WallpaperError.unreadable }
        let width = ScreenWallpaper.nativeWidth, height = ScreenWallpaper.nativeHeight
        let saved = SavedWallpaper(
            name: file.name,
            portrait: try Self.encode(image, width: width, height: height),
            landscape: try Self.encode(image, width: width, height: Int(ScreenWallpaper.landscapeCrop.height),
                                       padToPortrait: true),
            nativeLandscape: try Self.encode(image, width: height, height: width)
        )
        let wallpaper = try saved.makeWallpaper()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(saved).write(to: url, options: .atomic)
        } catch {
            throw WallpaperError.storageFailed
        }
        return wallpaper
    }

    func restoreDefault() throws -> ScreenWallpaper {
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw WallpaperError.storageFailed
            }
        }
        return .bundled
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    private static func encode(_ image: CGImage, width: Int, height: Int, padToPortrait: Bool = false) throws -> Data {
        guard let fittedContext = context(width: width, height: height) else {
            throw WallpaperError.encodingFailed
        }
        let fittedRect = CGRect(x: 0, y: 0, width: width, height: height)
        fittedContext.setFillColor(red: 0.12, green: 0.15, blue: 0.19, alpha: 1)
        fittedContext.fill(fittedRect)
        fittedContext.interpolationQuality = .high
        let scale = max(fittedRect.width / CGFloat(image.width), fittedRect.height / CGFloat(image.height))
        let drawWidth = CGFloat(image.width) * scale, drawHeight = CGFloat(image.height) * scale
        fittedContext.draw(image, in: CGRect(x: (fittedRect.width - drawWidth) / 2,
                                             y: (fittedRect.height - drawHeight) / 2,
                                             width: drawWidth, height: drawHeight))
        guard let fitted = fittedContext.makeImage() else { throw WallpaperError.encodingFailed }

        let native: CGImage
        if padToPortrait {
            // Extend the outer rows to keep JPEG compression from adding dark seams at the visible crop.
            let nativeHeight = ScreenWallpaper.nativeHeight
            guard let expanded = context(width: width, height: nativeHeight),
                  let top = fitted.cropping(to: CGRect(x: 0, y: 0, width: width, height: 1)),
                  let bottom = fitted.cropping(to: CGRect(x: 0, y: height - 1, width: width, height: 1)) else {
                throw WallpaperError.encodingFailed
            }
            let topHeight = Int(ScreenWallpaper.landscapeCrop.minY)
            let bottomHeight = nativeHeight - height - topHeight
            expanded.interpolationQuality = .none
            expanded.draw(bottom, in: CGRect(x: 0, y: 0, width: width, height: bottomHeight))
            expanded.draw(fitted, in: CGRect(x: 0, y: bottomHeight, width: width, height: height))
            expanded.draw(top, in: CGRect(x: 0, y: bottomHeight + height, width: width, height: topHeight))
            guard let expanded = expanded.makeImage() else { throw WallpaperError.encodingFailed }
            native = expanded
        } else {
            native = fitted
        }

        guard let jpeg = encodeImageJPEG(native, maxBytes: ScreenWallpaper.maxJPEGBytes,
                                         qualities: [0.92, 0.85, 0.76, 0.65, 0.48, 0.32, 0.20]) else {
            throw WallpaperError.encodingFailed
        }
        return jpeg
    }
}

private struct DeskWallpaperKey: EnvironmentKey {
    static let defaultValue: WallpaperFrame? = nil
}

extension EnvironmentValues {
    var deskWallpaper: WallpaperFrame? {
        get { self[DeskWallpaperKey.self] }
        set { self[DeskWallpaperKey.self] = newValue }
    }
}
