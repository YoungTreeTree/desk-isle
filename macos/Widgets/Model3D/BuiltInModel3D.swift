import Foundation

enum BuiltInModel3D: String, CaseIterable, Identifiable, Sendable {
    case bb8

    var id: Self { self }
    var title: String { "BB8" }
    var summary: String { "左右滚动，停下来轻轻晃头" }
    var modelFilename: String { "bb8-rolling" }
    var previewFilename: String { "bb8-preview" }

    // A packaged app must use its own resources, never an absolute build-machine fallback.
    static func resources(in application: Bundle = .main) throws -> Bundle {
        guard application.bundleURL.pathExtension == "app" else { return .module }
        guard let url=application.resourceURL?.appendingPathComponent("DeskIsle_DeskIsle.bundle"),
              FileManager.default.fileExists(atPath:url.path),
              let bundle=Bundle(url:url) else {
            throw Model3DError.invalid("应用内置模型资源缺失，请重新安装桌屿，或导入自定义 GLB。")
        }
        return bundle
    }

    func modelURL(in resources: Bundle) throws -> URL {
        guard let url=resources.url(forResource:modelFilename,withExtension:"glb",subdirectory:"Model3D") else {
            throw Model3DError.invalid("找不到内置 \(title) 模型，请重新安装桌屿，或导入自定义 GLB。")
        }
        return url
    }

    var previewURL: URL? {
        (try? Self.resources())?.url(forResource:previewFilename,withExtension:"png",subdirectory:"Model3D")
    }

    func load() throws -> Model3DFile {
        let url=try modelURL(in:Self.resources())
        return try Model3DFile(source:Data(contentsOf:url),name:title,quality:.smooth)
    }
}
