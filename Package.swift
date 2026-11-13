// swift-tools-version: 6.0
import PackageDescription
import Foundation

let miucs: Package.Dependency = ProcessInfo.processInfo.environment["MIUCS_LOCAL_PATH"]
    .flatMap { $0.isEmpty ? nil : $0 }
    .map { .package(path: $0) }
    ?? .package(url: "https://github.com/YoungTreeTree/miucs.git", revision: "d7a84e38377e156eb85660853ccc623b8f92704d")

let package = Package(
    name: "DeskIsle",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DeskIsle", targets: ["DeskIsle"])],
    dependencies: [miucs],
    targets: [
        .target(name: "DeskIsleCore", path: "shared", publicHeadersPath: "include"),
        .target(name: "DeskIsleNative", dependencies: ["DeskIsleCore"], path: "macos/Native", publicHeadersPath: "include"),
        .executableTarget(name: "DeskIsle", dependencies: ["DeskIsleNative", .product(name: "MiucsCore", package: "miucs")],
                          path: "macos", exclude: ["Native"]),
        .testTarget(name: "DeskIsleTests", dependencies: ["DeskIsle"], path: "tests/macos")
    ]
)
