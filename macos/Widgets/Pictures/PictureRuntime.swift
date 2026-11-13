import Foundation
import Combine


@MainActor
final class PictureRuntime: ObservableObject {
    @Published var pictures: [Int: PictureAsset] = [:]
    @Published var pictureDisplayNotices: [Int: String] = [:]
    private let usb: any PictureFrameTransport
    var context: () -> WidgetContext = { .idle }
    var appliedPictures: [Int: PictureAsset] = [:] {
        didSet { pictureDisplayNotices = [:]; nativePictures = []; boardManagedPictures = []; preparedAnimations = [:] }
    }
    @Published private(set) var nativePictures: Set<Int> = []
    private var boardManagedPictures: Set<Int> = []
    private var preparedAnimations: [Int: (asset: UUID, side: Int, animation: PictureAnimation)] = [:]
    private var picturePlayback: Task<Void, Never>?
    private var playbackSleep: Task<Void, Never>?
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
        playbackSleep?.cancel()
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
            // The periodic layout reply carries board residency. Checking native
            // animations here is a no-op on the wire unless the board lost its cache.
            if let picture = appliedPictures[component.id], !picture.isAnimated || boardManagedPictures.contains(component.id) {
                await displayPicture(picture, for: component, maxJPEG: layout.panel.maxJPEG)
            }
        }
    }

    func stopPicturePlayback() {
        picturePlayback?.cancel()
        playbackSleep?.cancel()
    }

    private var animatedPictures: [Component] {
        applied.components.filter { $0.isPicture && appliedPictures[$0.id]?.isAnimated == true && !boardManagedPictures.contains($0.id) }
    }

    func updatePicturePlayback() {
        guard connected, !applying, picturePlayback == nil, !animatedPictures.isEmpty else { return }
        playbackPaused = false
        picturePlayback = Task { [weak self] in await self?.playPictures() }
    }

    func playPictures() async {
        defer { picturePlayback = nil; playbackSleep = nil }
        var deadlines: [Int: (asset: UUID, time: TimeInterval)] = [:]
        while connected && !Task.isCancelled && !playbackPaused {
            let animated = animatedPictures
            guard !animated.isEmpty else { return }
            if applying {
                await sleepUntilNextFrame(0.1)
                continue
            }
            let ids = Set(animated.map(\.id))
            deadlines = deadlines.filter { ids.contains($0.key) }
            func deadline(_ component: Component) -> TimeInterval {
                guard let saved = deadlines[component.id], saved.asset == appliedPictures[component.id]?.id
                else { return -.infinity }
                return saved.time
            }
            // Each GIF has its own clock. Oldest due frame goes first; a second GIF
            // must not halve the first one's frame rate when the link has capacity.
            guard let component = animated.min(by: { deadline($0) < deadline($1) }),
                  let picture = appliedPictures[component.id] else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let delay = deadline(component) - now
            if delay > 0 {
                await sleepUntilNextFrame(delay)
                continue
            }
            await displayPicture(picture, for: component, maxJPEG: applied.panel.maxJPEG, at: now)
            // Include transfer time in the frame interval. If the link was slow,
            // the next iteration samples the current frame rather than queuing stale ones.
            let next = pictureDisplayNotices[component.id] == nil
                ? picture.nextFrameTime(after: now)
                : ProcessInfo.processInfo.systemUptime + 0.8
            deadlines[component.id] = (picture.id, next)
        }
    }

    private func sleepUntilNextFrame(_ delay: TimeInterval) async {
        // Wake a long-held GIF immediately for layout switching, without cancelling
        // an in-flight JPEG on the shared control connection.
        let sleep = Task<Void, Never> {
            do { try await Task.sleep(for: .seconds(delay)) } catch { }
        }
        playbackSleep = sleep
        await withTaskCancellationHandler {
            await sleep.value
        } onCancel: {
            sleep.cancel()
        }
        playbackSleep = nil
    }

    func displayPicture(_ asset: PictureAsset, for component: Component, maxJPEG: Int,
                        at time: TimeInterval? = nil) async {
        let start = revision
        let now = time ?? ProcessInfo.processInfo.systemUptime
        do {
            let native = asset.isAnimated ? try await usb.supportsPictureAnimation() : false
            guard revision == start, !Task.isCancelled else { return }
            if native {
                // A rejected native upload is retried by normal device polling, never
                // by silently falling back to continuous JPEG streaming.
                boardManagedPictures.insert(component.id)
                let packet: PictureAnimation
                if let cached = preparedAnimations[component.id], cached.asset == asset.id, cached.side == component.width {
                    packet = cached.animation
                } else {
                    let side = component.width
                    packet = try await Task.detached(priority: .utility) { try asset.animation(side: side) }.value
                    guard revision == start, !Task.isCancelled else { return }
                    preparedAnimations[component.id] = (asset.id, side, packet)
                }
                try await usb.showPictureAnimation(packet, for: component)
                guard revision == start, !Task.isCancelled else { return }
                if !nativePictures.contains(component.id) { nativePictures.insert(component.id) }
            } else {
                boardManagedPictures.remove(component.id)
                if nativePictures.contains(component.id) { nativePictures.remove(component.id) }
                guard let frame = asset.image(at: now, side: component.width) else { return }
                _ = try await usb.showFrame(frame.jpeg, alphaMask: frame.alphaMask, for: component, maxJPEG: maxJPEG)
            }
            if pictureDisplayNotices[component.id] != nil {
                pictureDisplayNotices.removeValue(forKey: component.id)
            }
        } catch {
            if revision == start, nativePictures.contains(component.id) { nativePictures.remove(component.id) }
            if revision == start, !Task.isCancelled, pictureDisplayNotices[component.id] == nil {
                pictureDisplayNotices[component.id] = error.localizedDescription
            }
        }
    }

}
