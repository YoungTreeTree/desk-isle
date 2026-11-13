import CoreGraphics
import CoreText
import Foundation

struct WidgetGlyphRun {
    let text: String
    let sizes: [Int]

    init(_ text: String?, _ sizes: Int...) {
        self.text = text ?? ""
        self.sizes = sizes
    }
}

protocol WidgetGlyphSource: Encodable, Sendable {
    var glyphRuns: [WidgetGlyphRun] { get }
}

struct WidgetGlyphRasterizer {
    private let face: CGFont?

    init(url: URL? = Bundle.main.url(forResource: "MiSans-Regular", withExtension: "ttf")) {
        face = url.flatMap { CGDataProvider(url: $0 as CFURL) }.flatMap { CGFont($0) }
    }

    func packet(json: Data, runs: [WidgetGlyphRun], limit: Int) -> Data? {
        guard let face, limit > json.count + 4 else { return nil }
        // Every ASCII glyph at the dynamic text sizes is already in the firmware.
        var keys = Set<UInt32>()
        for run in runs {
            for scalar in run.text.unicodeScalars where scalar.value >= 127 {
                for size in run.sizes {
                    keys.insert(UInt32(size) << 21 | scalar.value)
                }
            }
        }

        var fonts: [Int: CTFont] = [:]
        var directory = Data(), masks = Data()
        var count: UInt16 = 0
        for key in keys.sorted() {
            let size = Int(key >> 21)
            guard let scalar = Unicode.Scalar(key & 0x1fffff) else { continue }
            let font = fonts[size] ?? CTFontCreateWithGraphicsFont(face, CGFloat(size), nil, nil)
            fonts[size] = font
            guard let glyph = rasterize(scalar, font: font) else { continue }
            if json.count + 4 + directory.count + 13 + masks.count + glyph.mask.count > limit { break }
            directory.appendLE(key)
            directory.appendLE(UInt32(masks.count))
            directory.append(contentsOf: glyph.metrics)
            masks.append(glyph.mask)
            count += 1
        }
        guard count > 0 else { return nil }
        var result = Data()
        result.appendLE(UInt16(json.count))
        result.append(json)
        result.appendLE(count)
        result.append(directory)
        result.append(masks)
        return result
    }

    private func rasterize(_ scalar: Unicode.Scalar, font: CTFont) -> (metrics: [UInt8], mask: Data)? {
        let characters = Array(String(scalar).utf16)
        var mapped = [CGGlyph](repeating: 0, count: characters.count)
        _ = CTFontGetGlyphsForCharacters(font, characters, &mapped, characters.count)
        guard var glyph = mapped.first, glyph != 0 else { return nil }

        let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
        let left = bounds.isEmpty ? 0 : Int(floor(bounds.minX))
        let right = bounds.isEmpty ? 0 : Int(ceil(bounds.maxX))
        let bottom = bounds.isEmpty ? 0 : Int(floor(bounds.minY))
        let top = bounds.isEmpty ? 0 : Int(ceil(bounds.maxY))
        let width = right - left, height = top - bottom
        let inset = max(0, -left)
        let naturalAdvance = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)
        let advance = max(1, max(right, Int(ceil(naturalAdvance))) + inset)
        guard advance <= 96, (0...96).contains(height), (-96...96).contains(top), bottom >= -96 else { return nil }

        let metrics = [UInt8(advance), UInt8(left + inset), UInt8(bitPattern: Int8(-top)), UInt8(width), UInt8(height)]
        if width == 0 || height == 0 { return (metrics, Data()) }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drew = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setShouldSmoothFonts(false)
            context.setFillColor(gray: 1, alpha: 1)
            var baseline = CGPoint(x: -left, y: -bottom)
            CTFontDrawGlyphs(font, &glyph, &baseline, 1, context)
            return true
        }
        guard drew else { return nil }
        var mask = Data(capacity: (pixels.count + 1) / 2)
        for index in stride(from: 0, to: pixels.count, by: 2) {
            let low = UInt8((Int(pixels[index]) * 15 + 127) / 255)
            let high = index + 1 < pixels.count ? UInt8((Int(pixels[index + 1]) * 15 + 127) / 255) : 0
            mask.append(low | high << 4)
        }
        return (metrics, mask)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
