import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Offline documentation fixture. No polling, USB, hooks, account probes or input capture is started.
@main
struct PreviewMain {
    @MainActor static func main() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.appearance = NSAppearance(named: .aqua)
        application.finishLaunching()
        guard CommandLine.arguments.count >= 2 else { fatalError("Pass an output directory") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let stateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskisle-documentation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateRoot) }
        let domain = "com.deskisle.documentation.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        preferences.set(false, forKey: "pet.enabled")
        let usb = LayoutUSB()
        let settings = ConnectionSettings(preferences: preferences, inspectConnections: false,
                                          garminStore: GarminSessionStore(root: stateRoot.appendingPathComponent("garmin")))
        settings.completeSetup()
        settings.updateCodex { $0.home = stateRoot.appendingPathComponent("codex").path }
        let display = DisplaySettings(usb: usb, preferences: preferences)
        let pet = PetSettings(usb: usb, preferences: preferences, importLegacySettings: false)
        let editor = LayoutEditor(usb: usb, displaySettings: display, connections: settings, petSettings: pet,
                                  libraryStore: LayoutLibraryStore(root: stateRoot.appendingPathComponent("Layouts")))
        if CommandLine.arguments.contains("--resources") {
            try resourcePreviews(editor: editor, output: output, stateRoot: stateRoot)
            return
        }
        let wallpaper = try makeWallpaper()
        editor.wallpaper = wallpaper
        editor.connected = true
        editor.widgetVersion = 2
        editor.draft = ScreenLayout(panel: .deskIsle, direction: .left, components: [
            placed(.garmin, column: 0, row: 10), placed(.codex, column: 22, row: 10),
            placed(.notifications, column: 5, row: 0), placed(.pet, column: 9, row: 10),
            placed(.bluetooth, column: 24, row: 6), placed(.macLoad, column: 24, row: 1),
        ])
        editor.applied = editor.draft
        editor.showingLibrary = false
        editor.selectedID = Component.notificationsID
        let instant: TimeInterval = 1_800_000_000
        editor.widgets.garminContent = GarminCardContent(snapshot: GarminSnapshot(
            fetchedAt: instant, lastSyncAt: instant, steps: 6420, stepGoal: 8000,
            sleepSeconds: 27000, sleepScore: 86, bodyBattery: 72, restingHeartRate: 58, hrv: 56,
            stress: (0..<72).map { 10 + ($0 * 17 + 9) % 55 }))
        editor.widgets.codexData = CodexCardData(day: "example", plan: "Plus",
            week: CodexQuota(usedPercent: 32, windowDurationMins: 10080, resetsAt: nil),
            fiveHours: CodexQuota(usedPercent: 14, windowDurationMins: 300, resetsAt: nil),
            tokens: 1_240_000, localTokens: true, staleQuotas: false)
        editor.widgets.bluetoothContent = BluetoothCardContent(computerBattery: 92, accessories: .connected([
            BluetoothDevice(name: "Keyboard", symbol: "keyboard", battery: 86, leftBattery: nil, rightBattery: nil, caseBattery: nil),
            BluetoothDevice(name: "Headphones", symbol: "headphones", battery: 74, leftBattery: nil, rightBattery: nil, caseBattery: nil),
        ]))
        editor.widgets.macLoad = MacLoadSnapshot(cpu: 18, gpu: 12, cpuTemperature: 46, systemPowerTenths: 112,
            memoryUsedMiB: 11264, memoryTotalMiB: 32768, memoryPressure: .normal, miucsTenths: nil, deskIsleTenths: 4)
        let running = snapshot(.running, title: "为新组件补充测试", body: "正在验证布局和设备协议", running: 1)
        editor.widgets.notificationMotion.update(to: running, at: 0)
        try saveWindow(WindowFrame { DeskIsleWindow(editor: editor, displaySettings: display) },
                 size: CGSize(width: 1320, height: 820), to: output.appendingPathComponent("layout-preview.png"))
        try saveWindow(WindowFrame {
            ConnectionSettingsView(editor: editor, settings: settings, showLayout: {})
        }, size: CGSize(width: 1100, height: 740), to: output.appendingPathComponent("connections-preview.png"))
        try save(NoticeGallery(wallpaper: wallpaper, snapshots: [running,
            snapshot(.approval, title: "等待你的确认", body: "Agent 请求执行下一步操作", waiting: 1),
            snapshot(.success, title: "任务已完成", body: "组件测试通过，结果已准备好查看"),
        ]), size: CGSize(width: 1040, height: 720), to: output.appendingPathComponent("notifications-preview.png"))
        print("Rendered three previews with synthetic data")
    }

    static func placed(_ kind: BuiltInPlugin, column: Int, row: Int) -> Component {
        let layout = ScreenLayout(panel: .deskIsle, direction: .left, components: [])
        var component = WidgetRegistry.definition(for: kind).makeComponent(in: layout)!
        component.place(at: GridPosition(column: column, row: row))
        return component
    }

    static func snapshot(_ style: NotificationSnapshot.Style, title: String, body: String,
                         running: Int = 0, waiting: Int = 0) -> NotificationSnapshot {
        NotificationSnapshot(item: .init(style: style, source: "codex", sessionID: nil,
                                        title: title, body: body, project: "demo-project", elapsedSeconds: 42),
                             running: running, waiting: waiting)
    }

    @MainActor static func makeWallpaper() throws -> ScreenWallpaper {
        func jpeg(_ size: CGSize) throws -> Data {
            let renderer = ImageRenderer(content: DemoWallpaper().frame(width: size.width, height: size.height))
            guard let image = renderer.cgImage else { throw PreviewError.render }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw PreviewError.render }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw PreviewError.render }
            return data as Data
        }
        let portrait = try jpeg(CGSize(width: 720, height: 1280))
        let landscape = try jpeg(CGSize(width: 1280, height: 720))
        return ScreenWallpaper(name: "示例渐变", portrait: WallpaperFrame(jpeg: portrait, landscape: false),
                               landscape: WallpaperFrame(jpeg: portrait, landscape: true, nativeLandscape: landscape))
    }

    @MainActor static func save<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let content = view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .light).environment(\.locale, Locale(identifier: "zh_CN"))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1.5
        guard let image = renderer.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw PreviewError.render }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PreviewError.render }
        print(url.lastPathComponent)
    }

    /// AppKit-backed controls and scroll views require a hosting window, not ImageRenderer.
    /// Render only this isolated fixture's view; never capture the user's desktop or other windows.
    @MainActor static func saveWindow<V: View>(_ view: V, size: CGSize, to url: URL, settle: TimeInterval = 0.3,
                                             scheme: ColorScheme = .light) throws {
        let content = view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "zh_CN"))
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw PreviewError.render }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.render }
        try data.write(to: url)
        print(url.lastPathComponent)
    }

    enum PreviewError: Error { case render }

    @MainActor static func resourcePreviews(editor: LayoutEditor, output: URL, stateRoot: URL) throws {
        let names = ["薄雾山谷", "暮色渐变", "海盐蓝", "暖沙", "鼠尾草"]
        for (index, name) in names.enumerated() {
            let image = LinearGradient(colors: [.init(hue: Double(index)*0.18, saturation: 0.24, brightness: 0.88),
                                                 .init(hue: Double(index)*0.18+0.06, saturation: 0.44, brightness: 0.5)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
            let url = stateRoot.appendingPathComponent("\(name).png")
            try save(image, size: CGSize(width: 400, height: 300), to: url)
            let id = try editor.libraryStore.storePicture(PictureFile(from: url))
            try editor.libraryStore.resources.recordUse(of: id)
            if index == 0 {
                let (wallpaperID, wallpaper) = try editor.libraryStore.importWallpaper(from: url)
                editor.draftWallpaperID = wallpaperID
                editor.wallpaper = wallpaper
                let entry = try editor.libraryStore.resources.load().entries.first { $0.assetIDs.contains(id) }!
                try editor.libraryStore.resources.setFavorite(true, id: entry.id)
            }
        }
        let model = try BuiltInModel3D.bb8.load()
        let id = try editor.libraryStore.storeModel(model)
        try editor.libraryStore.resources.recordUse(of: id)
        let entry = try editor.libraryStore.resources.load().entries.first { $0.assetIDs.contains(id) }!
        guard let thumbnail = ModelResourceThumbnail.render(model) else { throw PreviewError.render }
        let thumbnailURL = editor.libraryStore.resources.thumbnails.appendingPathComponent("\(entry.id).png")
        try FileManager.default.createDirectory(at: thumbnailURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(thumbnailURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw PreviewError.render }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { throw PreviewError.render }
        try Data(contentsOf: thumbnailURL).write(to: output.appendingPathComponent("model-thumbnail.png"))
        editor.recordDraftChange()
        _ = editor.flushLayoutSave()
        try saveWindow(ResourceLibraryView(editor: editor, request: ResourcePickerRequest(purpose: .manage, layoutID: editor.library.editingID)),
                       size: CGSize(width: 740, height: 680), to: output.appendingPathComponent("resources-preview.png"), settle: 2)
        try saveWindow(ResourceLibraryView(editor: editor, request: ResourcePickerRequest(purpose: .wallpaper, layoutID: editor.library.editingID)),
                       size: CGSize(width: 740, height: 680), to: output.appendingPathComponent("wallpaper-picker-preview.png"), settle: 1)
        try saveWindow(ResourceLibraryView(editor: editor, request: ResourcePickerRequest(purpose: .manage, layoutID: editor.library.editingID)),
                       size: CGSize(width: 740, height: 680), to: output.appendingPathComponent("resources-dark-preview.png"), settle: 1, scheme: .dark)
        print("Rendered resource library, wallpaper picker and model thumbnail with synthetic data")
    }
}

private struct DemoWallpaper: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            ZStack {
                LinearGradient(colors: [Color(red: 0.84, green: 0.90, blue: 0.99),
                                        Color(red: 0.92, green: 0.87, blue: 0.94),
                                        Color(red: 0.98, green: 0.87, blue: 0.78)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Ellipse().fill(Color(red: 0.55, green: 0.69, blue: 0.84).opacity(0.28))
                    .frame(width: w * 1.2, height: h * 0.8).rotationEffect(.degrees(-18)).position(x: w * 0.25, y: h * 0.95)
                Ellipse().fill(Color.white.opacity(0.30)).frame(width: w * 0.8, height: h * 0.6)
                    .rotationEffect(.degrees(-18)).position(x: w * 0.9, y: h * 0.22)
                VStack(spacing: 10) {
                    Text("DESK ISLE").font(.system(size: 52, weight: .ultraLight, design: .rounded)).tracking(9)
                    Text("把喜欢的信息，放在手边").font(.system(size: 19, weight: .light)).tracking(4)
                }.foregroundStyle(Color(red: 0.23, green: 0.31, blue: 0.46).opacity(0.45))
                    .position(x: w * 0.48, y: h * 0.40)
            }
        }.clipped()
    }
}

private struct WindowFrame<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color.red.opacity(0.75), .yellow, .green.opacity(0.8)], id: \.self) { color in
                    Circle().fill(color).frame(width: 11, height: 11)
                }
                Text("桌屿").font(.system(size: 13, weight: .semibold)).padding(.leading, 12)
                Spacer()
                Text("示例数据").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).frame(height: 36).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            content()
        }.background(.white)
    }
}

private struct NoticeGallery: View {
    let wallpaper: ScreenWallpaper
    let snapshots: [NotificationSnapshot]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("通知岛").font(.system(size: 30, weight: .semibold))
            Text("运行中 · 等待确认 · 已完成").font(.system(size: 16)).foregroundStyle(.secondary)
            ForEach(snapshots.indices, id: \.self) { index in
                let motion = motion(for: snapshots[index])
                NotificationCardPreview(motion: motion, footprint: .notificationWide,
                                        screenSize: CGSize(width: 1280, height: 720), origin: .zero, animates: false)
                    .frame(height: index == 0 ? 100 : 210, alignment: .top).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            Text("实际 SwiftUI 视图 · 固定示例数据").font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.95, green: 0.96, blue: 0.98)).environment(\.deskWallpaper, wallpaper.landscape)
    }
    private func motion(for snapshot: NotificationSnapshot) -> NotificationMotion {
        var value = NotificationMotion(); value.update(to: snapshot, at: 0); return value
    }
}
