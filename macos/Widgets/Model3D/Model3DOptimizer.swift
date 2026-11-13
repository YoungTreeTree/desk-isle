import Foundation
import DeskIsleMesh

/// Creates a derived runtime pack; vertex attributes remain tied to their original
/// indices so morph animation and material seams survive the simplification.
enum Model3DOptimizer {
    static func optimize(_ pack: Data) throws -> (pack: Data, triangles: Int, vertices: Int) {
        func invalid() -> Model3DError { .invalid("无法为这个模型生成流畅版，请使用原始细节。") }
        func uint32(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= pack.count - 4 else { throw invalid() }
            return pack.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        guard pack.count >= 20, pack.prefix(4) == Data("D3M1".utf8), try uint32(4) == 1 else { throw invalid() }
        let jsonSize = Int(try uint32(8))
        guard jsonSize > 0, jsonSize <= pack.count - 16,
              let document = try JSONSerialization.jsonObject(with: pack.subdata(in: 16..<16+jsonSize)) as? [String: Any],
              let originalTriangles = document["triangles"] as? Int,
              let originalVertices = document["vertices"] as? Int,
              var meshes = document["meshes"] as? [[String: Any]],
              var textures = document["textures"] as? [[String: Any]],
              var clips = document["clips"] as? [[String: Any]] else { throw invalid() }
        if originalTriangles <= 12_000 { return (pack, originalTriangles, originalVertices) }
        let binary = pack.subdata(in: 16+jsonSize..<pack.count)
        var output = Data()
        func bytes(_ offset: Int, _ size: Int) throws -> Data {
            guard offset >= 0, size >= 0, offset <= binary.count, size <= binary.count-offset else { throw invalid() }
            return binary.subdata(in: offset..<offset+size)
        }
        func floats(_ offset: Int, _ count: Int) throws -> [Float] {
            let data = try bytes(offset, count*4)
            return data.withUnsafeBytes { p in
                (0..<count).map { Float(bitPattern: UInt32(littleEndian: p.loadUnaligned(fromByteOffset: $0*4, as: UInt32.self))) }
            }
        }
        func append(_ data: Data) -> Int {
            let offset = output.count
            output.append(data)
            while output.count % 4 != 0 { output.append(0) }
            return offset
        }
        func remap(_ offset: Int, _ size: Int, _ indices: [Int]) throws -> Int {
            var result = Data(capacity: indices.count*size)
            for index in indices { result.append(try bytes(offset+index*size, size)) }
            return append(result)
        }
        var totalTriangles = 0, totalVertices = 0
        for mi in meshes.indices {
            var mesh = meshes[mi]
            guard let count = mesh["count"] as? Int, (1...150_000).contains(count),
                  let indexCount = mesh["indexCount"] as? Int, (3...300_000).contains(indexCount), indexCount % 3 == 0,
                  let position = mesh["position"] as? Int, let normal = mesh["normal"] as? Int,
                  let indexOffset = mesh["indices"] as? Int, let uv = mesh["uv"] as? Int,
                  let morphs = mesh["morphs"] as? [Int], morphs.count <= 4 else { throw invalid() }
            let positions = try floats(position, count*3), normals = try floats(normal, count*3)
            let coordinates = uv < 0 ? [] : try floats(uv, count*2)
            let deltas = try morphs.map { try floats($0, count*3) }
            let indexData = try bytes(indexOffset, indexCount*4)
            let indices: [UInt32] = indexData.withUnsafeBytes { p in
                (0..<indexCount).map { UInt32(littleEndian: p.loadUnaligned(fromByteOffset: $0*4, as: UInt32.self)) }
            }
            var extent: Float = 0
            for axis in 0..<3 {
                var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
                for v in 0..<count { low = min(low, positions[v*3+axis]); high = max(high, positions[v*3+axis]) }
                extent = max(extent, high-low)
            }
            let attributeCount = 3 + (uv < 0 ? 0 : 2) + morphs.count*3
            var weights = [Float](repeating: 0.1, count: 3)
            if uv >= 0 { weights += [1, 1] }
            weights += [Float](repeating: 1/max(extent, 0.000001), count: morphs.count*3)
            var attributes = [Float](); attributes.reserveCapacity(count*attributeCount)
            for v in 0..<count {
                attributes.append(contentsOf: normals[v*3..<v*3+3])
                if uv >= 0 { attributes.append(contentsOf: coordinates[v*2..<v*2+2]) }
                for delta in deltas { attributes.append(contentsOf: delta[v*3..<v*3+3]) }
            }
            var simplified = [UInt32](repeating: 0, count: indexCount)
            let target = indexCount <= 256*3 ? indexCount : min(indexCount, max(128, indexCount/30)*3)
            let retained = simplified.withUnsafeMutableBufferPointer { destination in
                indices.withUnsafeBufferPointer { source in
                    positions.withUnsafeBufferPointer { position in
                        attributes.withUnsafeBufferPointer { attributes in
                            weights.withUnsafeBufferPointer { weights in
                                desk_mesh_simplify(destination.baseAddress, source.baseAddress, indexCount,
                                    position.baseAddress, count, attributes.baseAddress, weights.baseAddress,
                                    attributeCount, target, 0.008)
                            }
                        }
                    }
                }
            }
            guard retained >= 3, retained <= indexCount, retained % 3 == 0 else { throw invalid() }
            var mapping = [Int](repeating: -1, count: count), kept: [Int] = [], remapped = Data(capacity: retained*4)
            for old in simplified.prefix(retained) {
                guard old < count else { throw invalid() }
                if mapping[Int(old)] < 0 { mapping[Int(old)] = kept.count; kept.append(Int(old)) }
                var index = UInt32(mapping[Int(old)]).littleEndian
                withUnsafeBytes(of: &index) { remapped.append(contentsOf: $0) }
            }
            mesh["position"] = try remap(position, 12, kept)
            mesh["normal"] = try remap(normal, 12, kept)
            mesh["uv"] = uv < 0 ? -1 : try remap(uv, 8, kept)
            mesh["morphs"] = try morphs.map { try remap($0, 12, kept) }
            mesh["indices"] = append(remapped)
            mesh["count"] = kept.count; mesh["indexCount"] = retained
            totalTriangles += retained/3; totalVertices += kept.count; meshes[mi] = mesh
        }
        for i in textures.indices {
            guard let offset = textures[i]["offset"] as? Int, let width = textures[i]["width"] as? Int,
                  let height = textures[i]["height"] as? Int, (1...512).contains(width), (1...512).contains(height) else { throw invalid() }
            textures[i]["offset"] = append(try bytes(offset, width*height*2))
        }
        for i in clips.indices {
            guard var tracks = clips[i]["tracks"] as? [[String: Any]] else { throw invalid() }
            for t in tracks.indices {
                guard let times = tracks[t]["times"] as? Int, let values = tracks[t]["values"] as? Int,
                      let count = tracks[t]["count"] as? Int, (1...4096).contains(count),
                      let size = tracks[t]["size"] as? Int, (1...4).contains(size) else { throw invalid() }
                tracks[t]["times"] = append(try bytes(times, count*4))
                tracks[t]["values"] = append(try bytes(values, count*size*4))
            }
            clips[i]["tracks"] = tracks
        }
        var metadata = document
        metadata["meshes"] = meshes; metadata["textures"] = textures; metadata["clips"] = clips
        metadata["triangles"] = totalTriangles; metadata["vertices"] = totalVertices
        var json = try JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys)
        while json.count % 4 != 0 { json.append(32) }
        var result = Data("D3M1".utf8)
        for value in [1, json.count, output.count] {
            var little = UInt32(value).littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        result.append(json); result.append(output)
        guard result.count <= Model3DImporter.maxPack else { throw invalid() }
        return (result, totalTriangles, totalVertices)
    }
}
