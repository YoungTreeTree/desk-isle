import Foundation
import Combine


@MainActor
final class PictureRuntime: ObservableObject {
    @Published var pictures: [Int: PictureAsset] = [:]
    @Published var pictureDisplayNotices: [Int: String] = [:]
    private let usb: any PictureFrameTransport
    var context: () -> WidgetContext = { .idle }
    var appliedPictures: [Int: PictureAsset] = [:] { didSet { pictureDisplayNotices = [:] } }
    private var picturePlayback: Task<Void, Never>?
    private var playbackPaused = false
    private var draft: ScreenLayout { context().draft }
    private var applied: ScreenLayout { context().applied }
    private var connected: Bool { context().connected }
    private var applying: Bool { context().applying }
    private var revision: Int { context().revision }

    init(usb: any PictureFrameTransport) { self.usb = usb }

    func discardUnusedPictures() {
        let used = Set(draft.components.filter(\.isPicture).map(\.id))
        pictures = pictures.filter { used.contains($0.key) }
    }

    func pausePlayback() async {
        // Finish the current serial packet. Cancellation halfway through a JPEG resets
        // the shared control connection and can make the next layout request fail.
        playbackPaused = true
        await picturePlayback?.value
    }

    func displayAllPictures(in layout: ScreenLayout) async {
        let start = revision
        for component in layout.components where component.isPicture {
            guard revision == start, !Task.isCancelled else { return }
            if let picture = appliedPictures[component.id] {
                await displayPicture(picture, for: component, maxJPEG: layout.panel.maxJPEG)
            }
        }
    }

    func displayStillPictures(in layout: ScreenLayout) async {
        let start = revision
        for component in layout.components where component.isPicture {
            guard revision == start, !Task.isCancelled else { return }
            if let picture = appliedPictures[component.id], !picture.isAnimated {
                await displayPicture(picture, for: component, maxJPEG: layout.panel.maxJPEG)
            }
        }
    }

    func stopPicturePlayback() {
        picturePlayback?.cancel()
    }

    private var animatedPictures: [Component] {
        applied.components.filter { $0.isPicture && appliedPictures[$0.id]?.isAnimated == true }
    }

    func updatePicturePlayback() {
        guard connected, !applying, picturePlayback == nil, !animatedPictures.isEmpty else { return }
        playbackPaused = false
        picturePlayback = Task { [weak self] in await self?.playPictures() }
    }

    func playPictures() async {
        defer { picturePlayback = nil }
        var next = 0
        while connected && !Task.isCancelled && !playbackPaused {
            let animated = animatedPictures
            guard !animated.isEmpty else { return }
            var delay = PictureAsset.frameInterval
            if !applying {
                let index = next % animated.count
                let component = animated[index]
                next = index + 1
                if let picture = appliedPictures[component.id] {
                    await displayPicture(picture, for: component, maxJPEG: applied.panel.maxJPEG)
                    if pictureDisplayNotices[component.id] != nil { delay = 0.8 }
                }
            }
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        }
    }

    func displayPicture(_ asset: PictureAsset, for component: Component, maxJPEG: Int) async {
        let now = ProcessInfo.processInfo.systemUptime
        guard let frame = asset.image(at: now, side: component.width) else { return }
        do {
            _ = try await usb.showFrame(frame.jpeg, alphaMask: frame.alphaMask, for: component, maxJPEG: maxJPEG)
            if pictureDisplayNotices[component.id] != nil {
                pictureDisplayNotices.removeValue(forKey: component.id)
            }
        } catch {
            if !Task.isCancelled, pictureDisplayNotices[component.id] == nil {
                pictureDisplayNotices[component.id] = "图片画面发送失败，稍后重试。"
            }
        }
    }

}
