import Foundation
import CoreGraphics
import ImageIO

enum Model3DError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
enum Model3DQuality: String, Codable, Sendable { case original, smooth }

/// Immutable local asset. The GLB is retained for reimport; only the prepared pack crosses USB.
struct Model3DFile: Codable, Sendable {
    var name: String
    var source: Data
    var pack: Data
    var triangles: Int
    var vertices: Int
    var textureSize: Int
    var quality: Model3DQuality?
    var sourceTriangles: Int?

    init(from url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 20, size <= 16 * 1024 * 1024 else { throw Model3DError.invalid("GLB 文件须小于 16 MiB。") }
        try self.init(source: Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent, quality: .smooth)
    }

    init(source: Data, name: String, quality: Model3DQuality) throws {
        guard source.count > 20, source.count <= 16*1024*1024 else { throw Model3DError.invalid("GLB 文件须小于 16 MiB。") }
        let converted = try Model3DImporter.convert(source)
        let prepared = quality == .smooth ? try Model3DOptimizer.optimize(converted.pack) : converted
        self.name = name; self.quality = quality; sourceTriangles = converted.triangles
        self.source = source; pack = prepared.pack
        triangles = prepared.triangles; vertices = prepared.vertices; textureSize = 512
    }
}

/// glTF geometry and clips are preserved, with 512 px RGB565 textures for the board's memory budget.
/// Built-in and imported GLBs share this importer; no model bytes are linked into firmware.
enum Model3DImporter {
    static let maxPack = 8 * 1024 * 1024
    private static func invalid(_ text: String = "模型文件无效或包含暂不支持的数据。") -> Model3DError { .invalid(text) }
    static func convert(_ data: Data) throws -> (pack: Data, triangles: Int, vertices: Int) {
        func u32(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else { throw invalid() }
            return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        guard data.count >= 28, try u32(0) == 0x46546C67, try u32(4) == 2,
              try u32(8) == data.count, try u32(16) == 0x4E4F534A else { throw invalid("请选择 glTF 2.0 的 GLB 模型。") }
        let jsonSize = Int(try u32(12))
        guard jsonSize > 0, jsonSize < data.count - 28,
              let doc = try JSONSerialization.jsonObject(with: data.subdata(in: 20..<20+jsonSize)) as? [String: Any],
              try u32(24 + jsonSize) == 0x004E4942 else { throw invalid() }
        let binSize = Int(try u32(20 + jsonSize)), binStart = 28 + jsonSize
        guard binSize == data.count - binStart,
              (doc["skins"] as? [Any] ?? []).isEmpty,
              (doc["extensionsRequired"] as? [Any] ?? []).isEmpty else {
            throw invalid("首版支持节点动画与 Morph 动画，暂不支持骨骼蒙皮或压缩扩展。")
        }
        let bin = data.subdata(in: binStart..<data.count)
        let accessors = doc["accessors"] as? [[String: Any]] ?? []
        let views = doc["bufferViews"] as? [[String: Any]] ?? []
        let nodes = doc["nodes"] as? [[String: Any]] ?? []
        let meshes = doc["meshes"] as? [[String: Any]] ?? []
        guard (1...64).contains(nodes.count), meshes.count <= 64 else { throw invalid("模型节点数超出首版支持范围（64）。") }
        var blob = Data(), cached: [Int: (Int, Int, Int)] = [:]
        func append32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { blob.append(contentsOf: $0) } }
        func accessor(_ id: Int) throws -> (offset: Int, count: Int, size: Int) {
            if let value = cached[id] { return value }
            guard accessors.indices.contains(id) else { throw invalid() }
            let a = accessors[id]
            guard let count = a["count"] as? Int, (1...600_000).contains(count),
                  let type = a["componentType"] as? Int, [5126,5125,5123,5121].contains(type),
                  let shape = a["type"] as? String, let size = ["SCALAR":1,"VEC2":2,"VEC3":3,"VEC4":4][shape],
                  !(a["normalized"] as? Bool ?? false) else { throw invalid() }
            func readView(_ vi: Int, start: Int, count: Int, size: Int, type: Int) throws -> [UInt32] {
                guard views.indices.contains(vi) else { throw invalid() }
                let view = views[vi], unit = type == 5121 ? 1 : type == 5123 ? 2 : 4
                let stride = view["byteStride"] as? Int ?? size * unit
                let viewStart = view["byteOffset"] as? Int ?? 0, viewSize = view["byteLength"] as? Int ?? 0
                guard (view["buffer"] as? Int ?? 0) == 0, stride >= size * unit, stride <= 256,
                      viewStart >= 0, viewSize >= 0, viewStart <= bin.count, viewSize <= bin.count - viewStart,
                      start >= 0, start <= viewSize,
                      (count - 1) * stride + size * unit <= viewSize - start else { throw invalid() }
                var result = [UInt32](); result.reserveCapacity(count * size)
                for i in 0..<count {
                    for k in 0..<size {
                        let at = viewStart + start + i * stride + k * unit
                        result.append(bin.withUnsafeBytes { p in
                            if unit == 1 { return UInt32(p[at]) }
                            if unit == 2 { return UInt32(UInt16(littleEndian:p.loadUnaligned(fromByteOffset:at,as:UInt16.self))) }
                            return UInt32(littleEndian:p.loadUnaligned(fromByteOffset:at,as:UInt32.self))
                        })
                    }
                }
                return result
            }
            var rawValues = try (a["bufferView"] as? Int).map {
                try readView($0,start:a["byteOffset"] as? Int ?? 0,count:count,size:size,type:type)
            } ?? [UInt32](repeating:0,count:count*size)
            if let sparse = a["sparse"] as? [String: Any] {
                guard let n = sparse["count"] as? Int, (1...count).contains(n),
                      let indices = sparse["indices"] as? [String: Any], let iv = indices["bufferView"] as? Int,
                      let it = indices["componentType"] as? Int, [5121,5123,5125].contains(it),
                      let values = sparse["values"] as? [String: Any], let vv = values["bufferView"] as? Int else { throw invalid() }
                let positions = try readView(iv,start:indices["byteOffset"] as? Int ?? 0,count:n,size:1,type:it)
                let replacements = try readView(vv,start:values["byteOffset"] as? Int ?? 0,count:n,size:size,type:type)
                for i in 0..<n {
                    guard positions[i] < count, i == 0 || positions[i] > positions[i-1] else { throw invalid() }
                    for k in 0..<size { rawValues[Int(positions[i])*size+k] = replacements[i*size+k] }
                }
            }
            let offset = blob.count
            for raw in rawValues {
                if type == 5126 {
                    let f = Float(bitPattern:raw)
                    guard f.isFinite, abs(f) <= 100_000 else { throw invalid() }
                    }
                append32(raw)
            }
            guard blob.count <= maxPack else { throw invalid("模型资源超过 8 MiB。") }
            cached[id] = (offset,count,size)
            return (offset,count,size)
        }
        func floatAccessor(_ id: Int, size: Int, count: Int? = nil) throws -> Int {
            guard accessors.indices.contains(id), accessors[id]["componentType"] as? Int == 5126 else { throw invalid() }
            let value = try accessor(id)
            guard value.size == size, count == nil || count == value.count else { throw invalid() }
            return value.offset
        }
        func vector(_ object: [String: Any], _ key: String, _ fallback: [Double]) throws -> [Double] {
            let value = object[key] as? [Double] ?? fallback
            guard value.count == fallback.count, value.allSatisfy({ $0.isFinite && abs($0) <= 10_000 }) else { throw invalid() }
            return value
        }
        var parents = Array(repeating: -1, count: nodes.count)
        for (index,node) in nodes.enumerated() {
            guard node["matrix"] == nil, node["skin"] == nil else { throw invalid("请将节点矩阵导出为位置、旋转、缩放。") }
            for child in node["children"] as? [Int] ?? [] {
                guard nodes.indices.contains(child), parents[child] == -1, child != index else { throw invalid() }
                parents[child] = index
            }
        }
        for index in nodes.indices {
            var seen = Set<Int>(), cursor = index
            while cursor >= 0 { guard seen.insert(cursor).inserted else { throw invalid() }; cursor = parents[cursor] }
        }
        var nativeNodes: [[String: Any]] = [], primitives: [[String: Any]] = [], vertices = 0, triangles = 0
        for (index,node) in nodes.enumerated() {
            var weights = node["weights"] as? [Double] ?? []
            if let mi = node["mesh"] as? Int {
                guard meshes.indices.contains(mi) else { throw invalid() }
                let m = meshes[mi]
                if weights.isEmpty { weights = m["weights"] as? [Double] ?? [] }
                for primitive in m["primitives"] as? [[String: Any]] ?? [] {
                    guard (primitive["mode"] as? Int ?? 4) == 4,
                          let attr = primitive["attributes"] as? [String: Int], let pi = attr["POSITION"],
                          let ni = attr["NORMAL"], let ii = primitive["indices"] as? Int else { throw invalid("模型需要三角面、法线和索引。") }
                    let pos = try accessor(pi), ind = try accessor(ii)
                    guard pos.size == 3, pos.count <= 100_000, ind.size == 1, ind.count % 3 == 0,
                          [5121,5123,5125].contains(accessors[ii]["componentType"] as? Int ?? 0) else { throw invalid() }
                    guard blob.withUnsafeBytes({ bytes in
                        (0..<ind.count).allSatisfy { UInt32(littleEndian:bytes.loadUnaligned(fromByteOffset:ind.offset+$0*4,as:UInt32.self)) < pos.count }
                    }) else { throw invalid("模型三角面引用了不存在的顶点。") }
                    let normal = try floatAccessor(ni,size:3,count:pos.count)
                    _ = try floatAccessor(pi,size:3,count:pos.count)
                    var p: [String: Any] = ["node":index,"count":pos.count,"position":pos.offset,"normal":normal,
                        "indices":ind.offset,"indexCount":ind.count,"material":primitive["material"] as? Int ?? 0,"uv":-1]
                    if let ui = attr["TEXCOORD_0"] { p["uv"] = try floatAccessor(ui,size:2,count:pos.count) }
                    let targets = primitive["targets"] as? [[String: Int]] ?? []
                    guard targets.count <= 4 else { throw invalid("首版最多支持 4 个 Morph 目标。") }
                    p["morphs"] = try targets.map { target -> Int in
                        guard let a = target["POSITION"] else { throw invalid() }
                        return try floatAccessor(a,size:3,count:pos.count)
                    }
                    if weights.isEmpty { weights = Array(repeating: 0, count: targets.count) }
                    primitives.append(p); vertices += pos.count; triangles += ind.count / 3
                }
            }
            guard weights.count <= 4, weights.allSatisfy({ $0.isFinite && abs($0) <= 10 }) else { throw invalid() }
            nativeNodes.append(["parent":parents[index],"p":try vector(node,"translation",[0,0,0]),
                "q":try vector(node,"rotation",[0,0,0,1]),"s":try vector(node,"scale",[1,1,1]),"weights":weights])
        }
        guard (1...100_000).contains(triangles), (1...150_000).contains(vertices), primitives.count <= 64 else {
            throw invalid("首版上限为 10 万三角面、15 万顶点。")
        }
        let images = doc["images"] as? [[String: Any]] ?? []
        var textures: [[String: Any]] = []
        for t in doc["textures"] as? [[String: Any]] ?? [] {
            guard textures.count < 8, let si = t["source"] as? Int, images.indices.contains(si),
                  let vi = images[si]["bufferView"] as? Int, views.indices.contains(vi),
                  let size = views[vi]["byteLength"] as? Int else { throw invalid("纹理必须内嵌在 GLB 中。") }
            let offset = views[vi]["byteOffset"] as? Int ?? 0
            guard offset >= 0, size > 0, offset <= bin.count, size <= bin.count - offset,
                  let source = CGImageSourceCreateWithData(bin.subdata(in: offset..<offset+size) as CFData,nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
                      kCGImageSourceThumbnailMaxPixelSize:512] as CFDictionary) else { throw invalid("无法解码内嵌纹理。") }
            let width = image.width, height = image.height
            var rgba = [UInt8](repeating:0,count:width*height*4)
            try rgba.withUnsafeMutableBytes { pixels in
                guard let context = CGContext(data:pixels.baseAddress,width:width,height:height,bitsPerComponent:8,
                      bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw invalid() }
                context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            }
            let start = blob.count
            for i in stride(from:0,to:rgba.count,by:4) {
                let color = UInt16(rgba[i] >> 3) << 11 | UInt16(rgba[i+1] >> 2) << 5 | UInt16(rgba[i+2] >> 3)
                blob.append(UInt8(color & 255)); blob.append(UInt8(color >> 8))
            }
            while blob.count % 4 != 0 { blob.append(0) }
            textures.append(["offset":start,"width":width,"height":height])
        }
        var materials: [[String: Any]] = []
        for material in doc["materials"] as? [[String: Any]] ?? [[:]] {
            guard (material["alphaMode"] as? String ?? "OPAQUE") == "OPAQUE" else { throw invalid("首版暂不支持半透明材质。") }
            let pbr = material["pbrMetallicRoughness"] as? [String: Any] ?? [:]
            let color = try vector(pbr,"baseColorFactor",[1,1,1,1])
            guard color.allSatisfy({ (0...1).contains($0) }) else { throw invalid("材质颜色数值超出范围。") }
            let texture = pbr["baseColorTexture"] as? [String: Any]
            guard texture?["extensions"] == nil, (texture?["texCoord"] as? Int ?? 0) == 0 else { throw invalid() }
            let ti = texture?["index"] as? Int ?? -1
            guard ti == -1 || textures.indices.contains(ti) else { throw invalid() }
            materials.append(["color":Array(color.prefix(3)),"texture":ti,"doubleSided":material["doubleSided"] as? Bool ?? false])
        }
        guard (1...32).contains(materials.count) else { throw invalid("首版支持最多 32 种材质。") }
        for primitive in primitives {
            guard let index=primitive["material"] as? Int, materials.indices.contains(index) else { throw invalid("模型引用了不存在的材质。") }
            if (materials[index]["texture"] as? Int ?? -1) >= 0, (primitive["uv"] as? Int ?? -1) < 0 {
                throw invalid("带纹理的模型需要 UV 坐标。")
            }
        }
        var clips: [[String: Any]] = []
        for animation in doc["animations"] as? [[String: Any]] ?? [] {
            guard clips.count < 8 else { throw invalid() }
            let samplers = animation["samplers"] as? [[String: Any]] ?? []
            var tracks: [[String: Any]] = [], duration: Float = 0
            for channel in animation["channels"] as? [[String: Any]] ?? [] {
                guard let target = channel["target"] as? [String: Any],let node = target["node"] as? Int,nodes.indices.contains(node),
                      let path = target["path"] as? String,let property = ["translation":0,"rotation":1,"scale":2,"weights":3][path],
                      let si = channel["sampler"] as? Int,samplers.indices.contains(si),
                      let input = samplers[si]["input"] as? Int,let output = samplers[si]["output"] as? Int else { throw invalid() }
                let interpolation = samplers[si]["interpolation"] as? String ?? "LINEAR"
                guard ["LINEAR","STEP"].contains(interpolation) else { throw invalid("请将曲线烘焙为 LINEAR 动画。") }
                let times = try accessor(input), values = try accessor(output)
                _ = try floatAccessor(input,size:1)
                guard accessors[output]["componentType"] as? Int == 5126 else { throw invalid() }
                let size = property == 1 ? 4 : property == 3 ? (nativeNodes[node]["weights"] as? [Double] ?? []).count : 3
                guard (1...4).contains(size), times.count <= 4096, values.count*values.size == times.count*size else { throw invalid() }
                let end = blob.withUnsafeBytes { Float(bitPattern: UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:times.offset+(times.count-1)*4,as:UInt32.self))) }
                guard end >= 0, end <= 600 else { throw invalid() }; duration = max(duration,end)
                let monotonic = blob.withUnsafeBytes { bytes in
                    var previous:Float = -1
                    for i in 0..<times.count {
                        let value=Float(bitPattern:UInt32(littleEndian:bytes.loadUnaligned(fromByteOffset:times.offset+i*4,as:UInt32.self)))
                        if value<0 || value<=previous { return false };previous=value
                    }
                    return true
                }
                guard monotonic else { throw invalid("动画关键帧时间顺序无效。") }
                tracks.append(["node":node,"path":property,"size":size,"count":times.count,"times":times.offset,"values":values.offset,"step":interpolation == "STEP"])
            }
            guard tracks.count <= 128 else { throw invalid() }
            clips.append(["name":animation["name"] as? String ?? "clip", "duration":max(0.001,duration),"tracks":tracks])
        }
        let metadata: [String: Any] = ["v":1,"vertices":vertices,"triangles":triangles,"nodes":nativeNodes,
            "meshes":primitives,"materials":materials,"textures":textures,"clips":clips]
        var json = try JSONSerialization.data(withJSONObject:metadata,options:.sortedKeys)
        while json.count % 4 != 0 { json.append(32) }
        guard json.count <= 256 * 1024 else { throw invalid("模型动画和节点描述超出支持范围。") }
        var pack = Data("D3M1".utf8)
        for value in [UInt32(1),UInt32(json.count),UInt32(blob.count)] {
            var little = value.littleEndian; withUnsafeBytes(of:&little) { pack.append(contentsOf:$0) }
        }
        pack.append(json); pack.append(blob)
        guard pack.count <= maxPack else { throw invalid("准备后的模型资源超过 8 MiB。") }
        return (pack,triangles,vertices)
    }
}
