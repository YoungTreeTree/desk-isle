import AppKit
import SwiftUI


private enum PreviewSpace: Hashable { case canvas }
enum PreviewActivity { case hidden, visible, active }

struct PreviewWindowProbe: NSViewRepresentable {
    @Binding var activity: PreviewActivity

    func makeNSView(context: Context) -> Probe { Probe(activity: $activity) }
    func updateNSView(_ view: Probe, context: Context) { view.activity = $activity }

    final class Probe: NSView {
        private static let windowChanges = [NSWindow.didChangeOcclusionStateNotification,
                                            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
        var activity: Binding<PreviewActivity>

        init(activity: Binding<PreviewActivity>) {
            self.activity = activity
            super.init(frame: .zero)
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(activityChanged), name: name, object: NSApp)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let window {
                for name in Self.windowChanges {
                    NotificationCenter.default.removeObserver(self, name: name, object: window)
                }
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                for name in Self.windowChanges {
                    NotificationCenter.default.addObserver(self, selector: #selector(activityChanged), name: name, object: window)
                }
            }
            activityChanged()
        }

        @objc private func activityChanged() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let next: PreviewActivity
                if let window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible) {
                    next = window.isKeyWindow && NSApp.isActive ? .active : .visible
                } else {
                    next = .hidden
                }
                if next != activity.wrappedValue { activity.wrappedValue = next }
            }
        }
    }
}

struct ScreenPreview: View {
    @ObservedObject var editor: LayoutEditor
    let activity: PreviewActivity

    var body: some View {
        let grid = editor.draft.grid
        let screenSize = CGSize(width: editor.draft.width, height: editor.draft.height)
        let wallpaper = editor.wallpaper.frame(for: editor.draft.direction)
        let animatedCount = editor.draft.components.count { $0.isPicture && editor.pictures[$0.id]?.isAnimated == true }
        let animationBytes = activity == .hidden ? 0 : PictureAsset.previewBudget / max(1, animatedCount)
        VStack(spacing: 8) {
            HStack {
                Text("屏幕预览").font(.headline)
                Spacer()
                Text("\(grid.columns) 列 × \(grid.rows) 行 · \(GridSize.cellPixels) px/格")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Menu {
                    Button("更换壁纸…") { editor.chooseWallpaper() }
                    Button("恢复默认壁纸") { editor.restoreDefaultWallpaper() }
                        .disabled(editor.draftWallpaperID == nil)
                } label: {
                    Label("壁纸", systemImage: "photo.on.rectangle")
                }
                .help(editor.wallpaper.title)
                .disabled(editor.importingWallpaper || editor.applying)
            }
            GeometryReader { geometry in
                let scale = min(geometry.size.width / screenSize.width, geometry.size.height / screenSize.height)
                let width = screenSize.width * scale
                let height = screenSize.height * scale
                ZStack(alignment: .topLeading) {
                    if let image = wallpaper?.image {
                        ScreenWallpaper.fitted(image, in: CGSize(width: width, height: height))
                            .accessibilityHidden(true)
                    } else {
                        Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                    }
                    PreviewGrid(grid: grid, cellLength: CGFloat(GridSize.cellPixels) * scale)
                    ForEach(editor.draft.components) { component in
                        PreviewComponent(component: component, scale: scale, grid: grid,
                                         screenSize: screenSize,
                                         garminContent: editor.garminContent,
                                         codexData: component.isCodex ? editor.codexData : nil,
                                         bluetoothContent: component.isBluetooth ? editor.bluetoothContent : .loading,
                                         macLoad: component.isMacLoad ? editor.macLoad : MacLoadSnapshot(),
                                         picture: component.isPicture ? editor.pictures[component.id] : nil,
                                         pictureAnimationBytes: animationBytes,
                                         animates: activity == .active,
                                         notificationMotion: component.isNotifications ? editor.notificationMotion : NotificationMotion(),
                                         selected: component.id == editor.selectedID,
                                         select: { editor.selectedID = component.id },
                                         move: { editor.move(component.id, to: $0) })
                    }
                }
                .environment(\.deskWallpaper, wallpaper)
                .frame(width: width, height: height)
                .coordinateSpace(name: PreviewSpace.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.2)) }
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(22)
        .allowsHitTesting(!editor.applying)
    }
}

private struct PreviewGrid: View {
    let grid: GridSize
    let cellLength: CGFloat

    var body: some View {
        Canvas { context, size in
            var lines = Path()
            for column in 1..<max(1, grid.columns) {
                let x = CGFloat(column) * cellLength
                lines.move(to: CGPoint(x: x, y: 0))
                lines.addLine(to: CGPoint(x: x, y: size.height))
            }
            for row in 1..<max(1, grid.rows) {
                let y = CGFloat(row) * cellLength
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(lines, with: .color(.black.opacity(0.3)), lineWidth: 1.4)
            context.stroke(lines, with: .color(.white.opacity(0.34)), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PreviewComponent: View {
    let component: Component
    let scale: CGFloat
    let grid: GridSize
    let screenSize: CGSize
    let garminContent: GarminCardContent
    let codexData: CodexCardData?
    let bluetoothContent: BluetoothCardContent
    let macLoad: MacLoadSnapshot
    let picture: PictureAsset?
    let pictureAnimationBytes: Int
    let animates: Bool
    let notificationMotion: NotificationMotion
    let selected: Bool
    let select: () -> Void
    let move: (GridPosition) -> Void
    @Environment(\.deskWallpaper) private var wallpaper
    @GestureState private var translation: CGSize? = nil

    private var cellLength: CGFloat { CGFloat(GridSize.cellPixels) * scale }

    private func destination(for offset: CGSize) -> GridPosition {
        let origin = component.position
        guard cellLength > 0 else { return origin }
        let position = GridPosition(column: origin.column + Int((offset.width / cellLength).rounded()),
                                    row: origin.row + Int((offset.height / cellLength).rounded()))
        return grid.clamped(position, for: component.footprint)
    }

    var body: some View {
        let footprint = component.footprint
        let width = CGFloat(footprint.columns) * cellLength
        let height = CGFloat(footprint.rows) * cellLength
        let x = CGFloat(component.position.column) * cellLength
        let y = CGFloat(component.position.row) * cellLength
        let dx = min(max(-x, translation?.width ?? 0), max(0, CGFloat(grid.columns) * cellLength - width - x))
        let dy = min(max(-y, translation?.height ?? 0), max(0, CGFloat(grid.rows) * cellLength - height - y))
        let pixelsPerPoint = scale > 0 ? 1 / scale : 0
        let origin = CGPoint(x: CGFloat(component.x) + dx * pixelsPerPoint,
                             y: CGFloat(component.y) + dy * pixelsPerPoint)
        ZStack {
            if component.isGarmin || component.isCodex || component.isBluetooth || component.isMacLoad {
                let size = CGSize(width: footprint.width, height: footprint.height)
                let material = wallpaper?.frostedMaterial(at: origin, size: size) ?? FrostedCardMaterial()
                Group {
                    if component.isGarmin {
                        GarminCard(content: garminContent, screenSize: screenSize, origin: origin, material: material)
                    } else if component.isCodex {
                        CodexUsageCard(usage: codexData, footprint: footprint, screenSize: screenSize,
                                       origin: origin, material: material)
                    } else if component.isBluetooth {
                        BluetoothCard(content: bluetoothContent, footprint: footprint, screenSize: screenSize,
                                      origin: origin, material: material)
                    } else {
                        MacLoadCard(sample: macLoad, footprint: footprint, screenSize: screenSize,
                                    origin: origin, material: material)
                    }
                }
                .scaleEffect(scale)
                .frame(width: width, height: height)
                .accessibilityHidden(true)
            } else if component.isPicture {
                PictureCardPreview(asset: picture, side: component.width, animationBytes: pictureAnimationBytes,
                                   isPlaying: animates)
                    .frame(width: width, height: height)
                    .accessibilityHidden(true)
            } else if component.isNotifications {
                NotificationCardPreview(motion: notificationMotion, footprint: footprint, screenSize: screenSize,
                                        origin: origin, animates: animates)
                    .scaleEffect(scale)
                    .frame(width: width, height: height)
                    .accessibilityHidden(true)
            } else {
                Rectangle().fill(component.isPet ? Color.clear : Color(red: 0.22, green: 0.24, blue: 0.29))
                if component.isPet && selected {
                    Rectangle()
                        .strokeBorder(.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: CGFloat(component.width) * scale, height: CGFloat(component.height) * scale)
                }
                if width >= 66 && height >= 28 {
                    Label(component.name, systemImage: component.symbol)
                        .font(.system(size: min(13, height / 2.6), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                }
            }
            if selected || component.isPet || component.isPlaceholder {
                Rectangle().strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.5), lineWidth: selected ? 2 : 1)
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .accessibilityLabel("\(component.name)，\(footprint.label)")
        .onTapGesture(perform: select)
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(PreviewSpace.canvas))
            .updating($translation) { value, state, _ in state = value.translation }
            .onEnded { value in move(destination(for: value.translation)) })
        .offset(x: dx, y: dy)
        .position(x: x + width / 2, y: y + height / 2)
        .overlay(alignment: .topLeading) {
            if let translation {
                let target = destination(for: translation)
                Rectangle()
                    .strokeBorder(.white, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    .frame(width: width, height: height)
                    .offset(x: CGFloat(target.column) * cellLength, y: CGFloat(target.row) * cellLength)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
