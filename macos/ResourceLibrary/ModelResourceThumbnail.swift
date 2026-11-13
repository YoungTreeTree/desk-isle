import AppKit
import SceneKit

/// One still image from the already prepared geometry; no live scene or animation is kept.
enum ModelResourceThumbnail {
    static func render(_ file: Model3DFile) -> CGImage? {
        autoreleasepool { renderGeometry(file) }
    }

    private static func renderGeometry(_ file: Model3DFile) -> CGImage? {
        let pack = file.pack
        guard pack.count >= 20, pack.prefix(4) == Data("D3M1".utf8) else { return nil }
        let length = pack.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self))) }
        guard length > 0, length <= pack.count - 16,
              let metadata = try? JSONSerialization.jsonObject(with: pack.subdata(in: 16..<16+length)) as? [String: Any],
              let nodes = metadata["nodes"] as? [[String: Any]], nodes.count <= 64,
              let meshes = metadata["meshes"] as? [[String: Any]], meshes.count <= 64 else { return nil }
        let binary = pack.subdata(in: 16+length..<pack.count)
        func bytes(_ offset: Int, _ count: Int) -> Data? {
            guard offset >= 0, count >= 0, offset <= binary.count, count <= binary.count - offset else { return nil }
            return binary.subdata(in: offset..<offset+count)
        }
        func vector(_ node: [String: Any], _ key: String, _ fallback: [Float]) -> [Float] {
            guard let value = node[key] as? [NSNumber], value.count == fallback.count,
                  value.allSatisfy({ $0.floatValue.isFinite && abs($0.floatValue) < 100_001 }) else { return fallback }
            return value.map(\.floatValue)
        }
        let scene = SCNScene(), root = SCNNode()
        scene.rootNode.addChildNode(root)
        let sceneNodes = nodes.map { node in
            let result = SCNNode()
            let p = vector(node, "p", [0, 0, 0]), q = vector(node, "q", [0, 0, 0, 1]), s = vector(node, "s", [1, 1, 1])
            result.position = SCNVector3(p[0], p[1], p[2])
            result.orientation = SCNQuaternion(q[0], q[1], q[2], q[3])
            result.scale = SCNVector3(s[0], s[1], s[2])
            return result
        }
        for (index, node) in nodes.enumerated() {
            let parent = node["parent"] as? Int ?? -1
            var cursor = parent, visited: Set<Int> = [index]
            while cursor >= 0 {
                guard nodes.indices.contains(cursor), visited.insert(cursor).inserted else { return nil }
                cursor = nodes[cursor]["parent"] as? Int ?? -1
            }
            if parent >= 0 { sceneNodes[parent].addChildNode(sceneNodes[index]) }
            else { root.addChildNode(sceneNodes[index]) }
        }
        let textures: [CGImage?] = (metadata["textures"] as? [[String: Any]] ?? []).prefix(8).map { texture in
            guard let width = texture["width"] as? Int, let height = texture["height"] as? Int,
                  (1...1024).contains(width), (1...1024).contains(height), let offset = texture["offset"] as? Int,
                  let data = bytes(offset, width * height * 2) else { return nil }
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            data.withUnsafeBytes { raw in
                for i in 0..<width*height {
                    let rgb = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: i*2, as: UInt16.self))
                    pixels[i*4] = UInt8((UInt32(rgb >> 11) * 255) / 31)
                    pixels[i*4+1] = UInt8((UInt32((rgb >> 5) & 63) * 255) / 63)
                    pixels[i*4+2] = UInt8((UInt32(rgb & 31) * 255) / 31)
                }
            }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        let materials = (metadata["materials"] as? [[String: Any]] ?? []).prefix(32).map { item in
            let material = SCNMaterial()
            material.lightingModel = .lambert
            material.isDoubleSided = item["doubleSided"] as? Bool ?? false
            let color = vector(item, "color", [0.7, 0.7, 0.7])
            let texture = item["texture"] as? Int ?? -1
            if textures.indices.contains(texture), let image = textures[texture] { material.diffuse.contents = image }
            else { material.diffuse.contents = NSColor(calibratedRed: CGFloat(color[0]), green: CGFloat(color[1]), blue: CGFloat(color[2]), alpha: 1) }
            return material
        }
        for mesh in meshes {
            guard let ni = mesh["node"] as? Int, sceneNodes.indices.contains(ni),
                  let count = mesh["count"] as? Int, (1...150_000).contains(count),
                  let indexCount = mesh["indexCount"] as? Int, (3...300_000).contains(indexCount), indexCount % 3 == 0,
                  let position = mesh["position"] as? Int, let normal = mesh["normal"] as? Int,
                  let indexOffset = mesh["indices"] as? Int,
                  let vertexData = bytes(position, count*12), let normalData = bytes(normal, count*12),
                  let indices = bytes(indexOffset, indexCount*4) else { return nil }
            let valid = indices.withUnsafeBytes { raw in
                (0..<indexCount).allSatisfy { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0*4, as: UInt32.self)) < count }
            }
            guard valid else { return nil }
            for data in [vertexData, normalData] {
                let finite = data.withUnsafeBytes { raw in
                    (0..<count*3).allSatisfy {
                        let value = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0*4, as: UInt32.self)))
                        return value.isFinite && abs(value) < 100_001
                    }
                }
                guard finite else { return nil }
            }
            func source(_ data: Data, _ semantic: SCNGeometrySource.Semantic, _ size: Int) -> SCNGeometrySource {
                SCNGeometrySource(data: data, semantic: semantic, vectorCount: count, usesFloatComponents: true,
                                  componentsPerVector: size, bytesPerComponent: 4, dataOffset: 0, dataStride: size*4)
            }
            var sources = [source(vertexData, .vertex, 3), source(normalData, .normal, 3)]
            if let uv = mesh["uv"] as? Int, uv >= 0, let data = bytes(uv, count*8) { sources.append(source(data, .texcoord, 2)) }
            let geometry = SCNGeometry(sources: sources, elements: [SCNGeometryElement(data: indices, primitiveType: .triangles,
                                                                                      primitiveCount: indexCount/3, bytesPerIndex: 4)])
            if let index = mesh["material"] as? Int, materials.indices.contains(index) { geometry.materials = [materials[index]] }
            sceneNodes[ni].addChildNode(SCNNode(geometry: geometry))
        }
        let (low, high) = root.boundingBox
        let size = max(high.x-low.x, high.y-low.y, high.z-low.z)
        guard size.isFinite, size > 0 else { return nil }
        let center = SCNVector3((low.x+high.x)/2, (low.y+high.y)/2, (low.z+high.z)/2)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = Double(size) * 0.68
        camera.camera?.zNear = Double(size) * 0.001
        camera.camera?.zFar = Double(size) * 10
        camera.position = SCNVector3(center.x, center.y + size*0.12, center.z + size*3)
        camera.look(at: center)
        scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = true
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 360, height: 280), antialiasingMode: .multisampling4X)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
