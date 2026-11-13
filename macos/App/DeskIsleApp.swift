import AppKit
import SwiftUI


@MainActor
final class DeskIsleDelegate: NSObject, NSApplicationDelegate {
    let editor: LayoutEditor
    let displaySettings: DisplaySettings
    private var polling: Task<Void, Never>?

    override init() {
        let usb = LayoutUSB()
        let settings = DisplaySettings(usb: usb)
        displaySettings = settings
        editor = LayoutEditor(usb: usb, displaySettings: settings)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        editor.startNotifications()
        displaySettings.startFollowingSession()
        polling = Task {
            while !Task.isCancelled {
                await editor.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if editor.flushLayoutSave() { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "布局尚未保存"
        alert.informativeText = editor.libraryError ?? "请修复存储问题后重试。"
        alert.addButton(withTitle: "返回应用")
        alert.addButton(withTitle: "仍然退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        polling?.cancel()
        editor.synchronization?.cancel()
        editor.scenePreparation?.cancel()
        editor.editPreparation?.cancel()
        displaySettings.stopFollowingSession()
        editor.stopNotifications()
        editor.stopPicturePlayback()
        editor.connections.garminLogin.cancel()
        editor.petSettings.stop()
    }
}

@main
struct DeskIsleApp: App {
    @NSApplicationDelegateAdaptor(DeskIsleDelegate.self) private var delegate

    var body: some Scene {
        Window("桌屿", id: "main") {
            DeskIsleWindow(editor: delegate.editor, displaySettings: delegate.displaySettings)
                .frame(minWidth: 930, minHeight: 590)
        }
        .defaultSize(width: 1080, height: 650)
    }
}
