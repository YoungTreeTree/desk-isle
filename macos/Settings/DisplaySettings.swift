import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class DisplaySettings: NSObject, ObservableObject {
    enum Connection { case disconnected, needsFirmware, ready }

    @Published private(set) var brightness: Int
    @Published private(set) var followLock: Bool
    @Published private(set) var connection: Connection = .disconnected
    @Published private(set) var notice: String?

    private static let brightnessKey = "displayBrightness"
    private static let followLockKey = "displayFollowsMacLock"
    private static let macLocked = Notification.Name("com.apple.screenIsLocked")
    private static let macUnlocked = Notification.Name("com.apple.screenIsUnlocked")
    private let usb: LayoutUSB
    private let preferences: UserDefaults
    private var isLocked = false
    private var isOnConsole = true
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var syncTask: Task<Void, Never>?
    private var needsSync = false

    init(usb: LayoutUSB, preferences: UserDefaults = .standard) {
        self.usb = usb
        self.preferences = preferences
        brightness = min(100, max(0, preferences.object(forKey: Self.brightnessKey) as? Int ?? 100))
        followLock = preferences.object(forKey: Self.followLockKey) as? Bool ?? true
        super.init()
    }

    private var output: ScreenBacklight {
        ScreenBacklight(brightness: brightness, blanked: followLock && (isLocked || !isOnConsole))
    }

    func setBrightness(_ value: Int) {
        let value = min(100, max(0, value))
        guard value != brightness else { return }
        brightness = value
        preferences.set(value, forKey: Self.brightnessKey)
        requestSync()
    }

    func setFollowLock(_ enabled: Bool) {
        guard followLock != enabled else { return }
        followLock = enabled
        preferences.set(enabled, forKey: Self.followLockKey)
        requestSync()
    }

    func updateScreen(_ reply: LayoutReply?) async {
        let connection: Connection
        switch (reply, reply?.backlight) {
        case (nil, _): connection = .disconnected
        case (_, nil): connection = .needsFirmware
        case (_, .some): connection = .ready
        }
        if self.connection != connection { self.connection = connection }
        guard let backlight = reply?.backlight else {
            if notice != nil { notice = nil }
            return
        }
        if preferences.object(forKey: Self.brightnessKey) == nil, brightness != backlight.brightness {
            brightness = backlight.brightness
        }
        if backlight != output || notice != nil { requestSync() }
        await syncTask?.value
    }

    func startFollowingSession() {
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(macDidLock(_:)), name: Self.macLocked,
                                object: nil, suspensionBehavior: .deliverImmediately)
        distributed.addObserver(self, selector: #selector(macDidUnlock(_:)), name: Self.macUnlocked,
                                object: nil, suspensionBehavior: .deliverImmediately)

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.updateSession(onConsole: false) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.updateSession(onConsole: true) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.readSession() }
        readSession()
    }

    func stopFollowingSession() {
        DistributedNotificationCenter.default().removeObserver(self)
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        syncTask?.cancel()
    }

    @objc private func macDidLock(_ notification: Notification) { updateSession(locked: true) }
    @objc private func macDidUnlock(_ notification: Notification) { updateSession(locked: false) }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor @Sendable (DisplaySettings) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        observers.append((center, token))
    }

    private func readSession() {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return }
        updateSession(locked: session["CGSSessionScreenIsLocked"] as? Bool,
                      onConsole: session[kCGSessionOnConsoleKey as String] as? Bool)
    }

    private func updateSession(locked: Bool? = nil, onConsole: Bool? = nil) {
        let wasBlanked = output.blanked
        if let locked { isLocked = locked }
        if let onConsole { isOnConsole = onConsole }
        if output.blanked != wasBlanked { requestSync() }
    }

    private func requestSync() {
        needsSync = true
        guard connection == .ready, syncTask == nil else { return }
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer { syncTask = nil }
            while needsSync, connection == .ready, !Task.isCancelled {
                needsSync = false
                do {
                    try await usb.setBacklight(output)
                    if notice != nil { notice = nil }
                } catch {
                    notice = "小屏设置未同步，稍后重试。"
                }
            }
        }
    }
}

struct DisplaySettingsView: View {
    @ObservedObject var settings: DisplaySettings

    var body: some View {
        Form {
            Section("小屏") {
                LabeledContent("亮度") {
                    HStack(spacing: 12) {
                        Slider(value: Binding(get: { Double(settings.brightness) }, set: { settings.setBrightness(Int($0)) }),
                               in: 0...100, step: 1) { Text("亮度") }
                            .labelsHidden()
                            .accessibilityValue("\(settings.brightness)%")
                        Text("\(settings.brightness)%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                }
                .disabled(settings.connection == .needsFirmware)
                Toggle("Mac 锁屏时关闭小屏背光", isOn: Binding(get: { settings.followLock },
                                                           set: { settings.setFollowLock($0) }))
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var status: String? {
        if let notice = settings.notice { return notice }
        switch settings.connection {
        case .ready: return nil
        case .disconnected: return "等待连接小屏。"
        case .needsFirmware: return "更新小屏固件后可调节背光。"
        }
    }
}
