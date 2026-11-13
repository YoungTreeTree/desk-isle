import Foundation

struct PictureAnimation: Sendable {
    static let maxBytes = 4 * 1024 * 1024
    let data: Data
    let checksum: UInt32
    let frameCount: Int
    let durationMS: Int
}

struct PictureAnimationCapabilities: Sendable {
    let maxBytes: Int
    let chunkBytes: Int
    let cacheBytes: Int
    let maxFrames: Int

    init?(line: String, sequence: UInt32) {
        let f = line.split(separator: " ")
        guard f.count == 7, f[0] == "DESKISLE_PICTURES", f[1] == "1", UInt32(f[2]) == sequence,
              let bytes = Int(f[3]), (64...PictureAnimation.maxBytes).contains(bytes),
              let chunk = Int(f[4]), (256...32768).contains(chunk),
              let budget = Int(f[5]), (bytes...8 * 1024 * 1024).contains(budget),
              let frames = Int(f[6]), (2...144).contains(frames) else { return nil }
        maxBytes = bytes; chunkBytes = chunk; cacheBytes = budget; maxFrames = frames
    }
}

struct PictureResidency: Sendable {
    let bytes: Int
    let checksum: UInt32
    let width: Int
    let height: Int
    let state: Int

    static func parse(_ line: String, sequence: UInt32) -> (Int, Self)? {
        let f = line.split(separator: " ")
        guard f.count == 9, f[0] == "DESKISLE_PICTURE", f[1] == "1", UInt32(f[2]) == sequence,
              let id = Int(f[3]), Component.pictureIDs.contains(id),
              let bytes = Int(f[4]), (64...PictureAnimation.maxBytes).contains(bytes),
              let crc = UInt32(f[5]), let width = Int(f[6]), let height = Int(f[7]),
              GridSize.pictureSizes.contains(where: { $0.width == width && $0.height == height }),
              let state = Int(f[8]), (0...2).contains(state) else { return nil }
        return (id, Self(bytes: bytes, checksum: crc, width: width, height: height, state: state))
    }
}

struct PictureAnimationStats: Sendable {
    let id: Int
    let bytes: Int
    let checksum: UInt32
    let frameCount: Int
    let durationMS: Int
    let decoded: UInt64
    let presented: UInt64
    let elapsedUS: UInt64
    let decodeUS: UInt64
    let maxDecodeUS: UInt64
    let state: Int
    let freePSRAM: Int
    let largestPSRAM: Int

    init?(line: String, sequence: UInt32) {
        let f = line.split(separator: " ")
        guard f.count == 16, f[0] == "DESKISLE_PICTURE_STATS", f[1] == "1", UInt32(f[2]) == sequence,
              let id = Int(f[3]), Component.pictureIDs.contains(id),
              let bytes = Int(f[4]), let checksum = UInt32(f[5]),
              let count = Int(f[6]), let duration = Int(f[7]),
              let decoded = UInt64(f[8]), let presented = UInt64(f[9]), let elapsed = UInt64(f[10]),
              let decode = UInt64(f[11]), let maxDecode = UInt64(f[12]), let state = Int(f[13]),
              let free = Int(f[14]), let largest = Int(f[15]) else { return nil }
        self.id = id; self.bytes = bytes; self.checksum = checksum; frameCount = count; durationMS = duration
        self.decoded = decoded; self.presented = presented; elapsedUS = elapsed; decodeUS = decode
        maxDecodeUS = maxDecode; self.state = state; freePSRAM = free; largestPSRAM = largest
    }
}
