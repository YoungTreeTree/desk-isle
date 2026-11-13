import Foundation
import Combine


@MainActor
final class WidgetRuntime: ObservableObject {
    @Published var garminContent = GarminCardContent()
    @Published var garminDisplayNotice: String?
    @Published var codexData: CodexCardData?
    @Published var codexDisplayNotice: String?
    @Published var bluetoothContent = BluetoothCardContent.loading
    @Published var bluetoothDisplayNotice: String?
    @Published var macLoad = MacLoadSnapshot()
    @Published var macLoadDisplayNotice: String?
    @Published var notificationMotion = NotificationMotion()
    @Published var notificationListenError: String?
    @Published var notificationDisplayNotice: String?

    let usb: LayoutUSB
    let connections: ConnectionSettings
    var context: () -> WidgetContext = { .idle }
    private var connectionSubscription: AnyCancellable?
    private var previousProfile: ConnectionProfile
    var garminFetching = false
    var nextGarminRead: TimeInterval = 0
    var codexFetching = false
    var nextCodexRead = Date.distantPast
    var bluetoothFetching = false
    var nextBluetoothRead: TimeInterval = 0
    let macLoadSource = MacLoadSource()
    var macLoadFetching = false
    var nextMacLoadRead: TimeInterval = 0
    var notificationFeed = NotificationFeed()
    var notificationListener: DispatchSourceRead?
    var notificationNeedsDisplay = false
    var notificationSending = false

    init(usb: LayoutUSB, connections: ConnectionSettings) {
        self.usb = usb
        self.connections = connections
        previousProfile = connections.profile
        connectionSubscription = connections.$profile.dropFirst().sink { [weak self] profile in
            self?.connectionProfileChanged(profile)
        }
    }

    var draft: ScreenLayout { context().draft }
    var applied: ScreenLayout { context().applied }
    var connected: Bool { context().connected }
    var applying: Bool { context().applying }
    var notificationSnapshot: NotificationSnapshot { notificationMotion.snapshot }
    var usesCodex: Bool { draft.codex != nil || (connected && applied.codex != nil) }

    func refreshSources() {
        for definition in WidgetRegistry.all { definition.refresh?(self, false) }
    }

    func displayWidgets(in layout: ScreenLayout, while isCurrent: () -> Bool) async {
        for definition in WidgetRegistry.all {
            guard isCurrent(), !Task.isCancelled else { return }
            await definition.display?(self, layout)
        }
    }
    func sendWidget<State: WidgetGlyphSource>(_ state: State, to component: Component?,
                    notice: ReferenceWritableKeyPath<WidgetRuntime, String?>, expiresAt: Date? = nil,
                    after: State? = nil) async {
        var message: String?
        if let component {
            do {
                try await usb.showWidget(state, for: component, expiresAt: expiresAt, after: after)
            } catch {
                message = error.localizedDescription
            }
        }
        if !Task.isCancelled, self[keyPath: notice] != message { self[keyPath: notice] = message }
    }

    func connectionProfileChanged(_ profile: ConnectionProfile) {
        if previousProfile.codex != profile.codex {
            codexData = nil
            nextCodexRead = .distantPast
        }
        if previousProfile.garmin != profile.garmin {
            garminContent = GarminCardContent(error: profile.garmin.enabled ? .setup : .disabled)
            nextGarminRead = 0
        }
        previousProfile = profile
    }

    func checkCodexConnection() { refreshCodexIfNeeded(force: true) }
    func checkGarminConnection() { refreshGarminIfNeeded(force: true) }


}
