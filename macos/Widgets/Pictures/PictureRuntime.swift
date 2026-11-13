import Foundation
import Combine


@MainActor
final class PictureRuntime: ObservableObject {
    @Published var pictures: [Int: PictureAsset] = [:]
    @Published var pictureDisplayNotices: [Int: String] = [:]
    private let usb: LayoutUSB
    var context: () -> WidgetContext = { .idle }
    private var pictureLoads: Set<Int> = []
    private var picturePlayback: Task<Void, Never>?
    private var draft: ScreenLayout { context().draft }
    private var applied: ScreenLayout { context().applied }
    private var connected: Bool { context().connected }
    private var applying: Bool { context().applying }
    private var revision: Int { context().revision }

    init(usb: LayoutUSB) { self.usb = usb }

    func loadPicturesIfNeeded() {
        let missing = applied.components.filter { $0.isPicture && pictures[$0.id] == nil && !pictureLoads.contains($0.id) }
        guard !missing.isEmpty else { return }
        pictureLoads.formUnion(missing.map(\.id))
        Task {
            for component in missing {
                let id = component.id
                let asset = await Task.detached(priority: .utility) {
                    try? PictureAsset.prepare(PictureFile.load(for: id))
                }.value
                if pictures[id] == nil, let asset,
                   (draft.components + applied.components).contains(where: { $0.id == id && $0.isPicture }) {
                    pictures[id] = asset
                }
            }
            updatePicturePlayback()
        }
    }

    func discardUnusedPictures() {
        let used = Set((draft.components + applied.components).filter(\.isPicture).map(\.id))
        let unused = Set(pictures.keys).union(pictureDisplayNotices.keys).subtracting(used)
        for id in unused {
            pictures.removeValue(forKey: id)
            pictureDisplayNotices.removeValue(forKey: id)
        }
        pictureLoads.formIntersection(used)
    }

    func displayStillPictures(in layout: ScreenLayout) async {
        let start = revision
        for component in layout.components where component.isPicture {
            guard revision == start, !Task.isCancelled else { return }
            if let picture = pictures[component.id], !picture.isAnimated {
                await displayPicture(picture, for: component, maxJPEG: layout.panel.maxJPEG)
            }
        }
    }

    func stopPicturePlayback() {
        picturePlayback?.cancel()
    }

    private var animatedPictures: [Component] {
        applied.components.filter { $0.isPicture && pictures[$0.id]?.isAnimated == true }
    }

    func updatePicturePlayback() {
        guard connected, picturePlayback == nil, !animatedPictures.isEmpty else { return }
        picturePlayback = Task { [weak self] in await self?.playPictures() }
    }

    func playPictures() async {
        defer { picturePlayback = nil }
        var next = 0
        while connected && !Task.isCancelled {
            let animated = animatedPictures
            guard !animated.isEmpty else { return }
            var delay = PictureAsset.frameInterval
            if !applying {
                let index = next % animated.count
                let component = animated[index]
                next = index + 1
                if let picture = pictures[component.id] {
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
            try await usb.showFrame(frame.jpeg, alphaMask: frame.alphaMask, for: component, maxJPEG: maxJPEG)
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
