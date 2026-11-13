import Foundation

// Narrow, injectable control interface; widget and pet streams still use the shared USB owner.
protocol LayoutDevice: Sendable {
    func readLayout() async throws -> LayoutReply?
    func apply(_ layout: ScreenLayout) async throws -> LayoutReply
    func showWallpaper(_ image: WallpaperFrame, for panel: Panel) async throws -> Bool
    func showModel3D(_ pack: Data, scale: Int) async throws
}

extension LayoutDevice {
    func showModel3D(_ pack: Data,scale: Int) async throws { throw LayoutLibraryError.message("设备不支持 3D 模型。") }
}

extension LayoutUSB: LayoutDevice {}

protocol PictureFrameTransport: Sendable {
    func showFrame(_ jpeg: Data, alphaMask: Data?, for component: Component, maxJPEG: Int) async throws -> Bool
    func supportsPictureAnimation() async throws -> Bool
    func showPictureAnimation(_ animation: PictureAnimation, for component: Component) async throws
}

extension PictureFrameTransport {
    func supportsPictureAnimation() async -> Bool { false }
    func showPictureAnimation(_ animation: PictureAnimation, for component: Component) async throws {
        throw LayoutUSBError.message("小屏固件尚未支持板端 GIF 播放。")
    }
}

extension LayoutUSB: PictureFrameTransport {}
