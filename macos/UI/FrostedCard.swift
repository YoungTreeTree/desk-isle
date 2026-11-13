#if canImport(DeskIsleNative)
import DeskIsleNative
#endif
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct FrostedCardMaterial {
    let texture: CGImage?
    private let style: desk_frost_style

    init(texture: CGImage? = nil, dark: Bool = false) {
        self.texture = texture
        style = desk_frost_style_for(dark && texture != nil).pointee
    }

    var ink: Color { color(style.ink) }
    var muted: Color { color(style.muted) }
    var accent: Color { color(style.accent) }
    var chartAmber: Color { color(style.chart_amber) }
    var tileOpacity: Double { Double(style.tile_opacity) / 255 }
    var badgeOpacity: Double { Double(style.badge_opacity) / 255 }

    var sheen: LinearGradient {
        LinearGradient(stops: [
            .init(color: .white.opacity(Double(style.highlight) / 255), location: 0),
            .init(color: .white.opacity(Double(DESK_FROST_HIGHLIGHT_MID_OPACITY) / 255),
                  location: Double(DESK_FROST_HIGHLIGHT_MID) / 255),
            .init(color: .clear, location: Double(DESK_FROST_HIGHLIGHT_END) / 255),
            .init(color: .black.opacity(Double(style.shadow) / 255), location: 1),
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var rim: LinearGradient {
        LinearGradient(colors: [style.rim_top, style.rim_middle, style.rim_bottom].map {
            .white.opacity(Double($0) / 255)
        }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func color(_ rgb565: UInt16) -> Color {
        Color(red: Double(rgb565 >> 11) / 31,
              green: Double((rgb565 >> 5) & 63) / 63,
              blue: Double(rgb565 & 31) / 31)
    }
}

struct FrostedCardBackground: View {
    let size: CGSize
    let screenSize: CGSize
    let origin: CGPoint
    let material: FrostedCardMaterial

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(DESK_FROST_RADIUS), style: .circular)
        Group {
            if let texture = material.texture {
                ScreenWallpaper.portion(texture, size: size, screenSize: screenSize, origin: origin)
            } else {
                Color(white: Double(DESK_FROST_FALLBACK) / 255)
            }
        }
        .overlay { material.sheen }
        .clipShape(shape)
        .overlay { shape.strokeBorder(material.rim, lineWidth: 1) }
    }
}

func encodeImageJPEG(_ image: CGImage, maxBytes: Int, qualities: [Double]) -> Data? {
    for quality in qualities {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: false],
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        if CGImageDestinationFinalize(destination), bytes.length <= maxBytes { return bytes as Data }
    }
    return nil
}
