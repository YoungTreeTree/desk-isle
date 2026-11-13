import Foundation

// Narrow, injectable control interface; widget and pet streams still use the shared USB owner.
protocol LayoutDevice: Sendable {
    func readLayout() async throws -> LayoutReply?
    func apply(_ layout: ScreenLayout) async throws -> LayoutReply
    func showWallpaper(_ image: WallpaperFrame, for panel: Panel) async throws -> Bool
}

extension LayoutUSB: LayoutDevice {}

protocol PictureFrameTransport: Sendable {
    func showFrame(_ jpeg: Data, alphaMask: Data?, for component: Component, maxJPEG: Int) async throws -> Bool
}

extension LayoutUSB: PictureFrameTransport {}
