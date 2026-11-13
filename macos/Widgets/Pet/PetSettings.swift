import AppKit
import Combine
import MiucsCore
import SwiftUI

@MainActor
final class PetSettings: ObservableObject {
    @Published private(set) var skins: [PetSkin]
    @Published private(set) var selectedID: String
    @Published private(set) var enabled: Bool
    @Published private(set) var audioEnabled: Bool
    @Published private(set) var keyboardEnabled: Bool
    @Published private(set) var status = "等待连接小屏"
    @Published private(set) var keyboardState = KeyboardSourceState.stopped
    @Published private(set) var audioStatus = "已暂停"
    @Published private(set) var hasComponent = false

    private let audio = AudioEngine()
    private let keyboard = KeyboardEngine()
    private let session = NativePetSession()
    private let transport: SerialPetTransport
    let legacySkinID: String
    private let preferences: UserDefaults
    private var subscriptions = Set<AnyCancellable>()
    private var connected = false
    private var runningSkin: String?
    private var activeID: String?
    var onSelectionChange: (() -> Void)?
    var onReadinessChange: ((Bool) -> Void)?
    var onStatusChange: ((String) -> Void)?
    var nativeActive: Bool { session.active }
    var activeSkinID: String? { runningSkin }
    @Published var layoutName = "默认布局"
    private var audioStarted = false
    private var keyboardStarted = false
    private var audioStart: Task<Void, Never>?
    private var keyboardStart: Task<Void, Never>?

    init(usb: LayoutUSB, preferences: UserDefaults = .standard, importLegacySettings: Bool = true) {
        self.preferences = preferences
        transport = SerialPetTransport { try await usb.openPetChannel() }
        let legacy = importLegacySettings ? UserDefaults(suiteName: "com.miucs.app") : nil
        let catalog = PetCatalog.scan()
        skins = catalog
        let selected = preferences.string(forKey: "pet.skin") ?? legacy?.string(forKey: "MiucsSelectedVisualization.v1")
        let initialSkin = catalog.first(where: { $0.id == selected })?.id ?? catalog.first?.id ?? ""
        selectedID = initialSkin
        legacySkinID = initialSkin
        enabled = preferences.object(forKey: "pet.enabled") as? Bool ?? true
        audioEnabled = preferences.object(forKey: "pet.audio") as? Bool
            ?? legacy?.object(forKey: "MiucsAudioCapture.enabled") as? Bool ?? false
        keyboardEnabled = preferences.object(forKey: "pet.keyboard") as? Bool
            ?? (importLegacySettings && preferences.bool(forKey: "pet.keyboardPermissionRequested"))
        // Migrate once. Subsequent standalone Miucs preferences remain independent.
        preferences.set(selectedID, forKey: "pet.skin")
        preferences.set(audioEnabled, forKey: "pet.audio")
        session.$status.removeDuplicates().sink { [weak self] value in
            self?.status = value
            self?.onStatusChange?(value)
        }.store(in: &subscriptions)
        session.$active.removeDuplicates().sink { [weak self] in self?.onReadinessChange?($0) }.store(in: &subscriptions)
        keyboard.$state.removeDuplicates().sink { [weak self] in self?.keyboardState = $0 }.store(in: &subscriptions)
        audio.$status.removeDuplicates().sink { [weak self] in self?.audioStatus = $0 }.store(in: &subscriptions)
    }

    func update(connected: Bool, hasComponent: Bool) {
        self.connected = connected
        if self.hasComponent != hasComponent { self.hasComponent = hasComponent }
        reconcile()
    }

    func select(_ id: String) {
        guard selectedID != id, skins.contains(where: { $0.id == id }) else { return }
        selectedID = id
        onSelectionChange?()
    }

    func editSkin(_ id: String, layoutName: String) {
        selectedID = id
        self.layoutName = layoutName
    }

    func pauseForLayoutChange(skinID: String, hasPet: Bool) async {
        // Geometry-only switches can keep the existing board session and input stream.
        guard !hasPet || runningSkin != skinID else { return }
        update(connected: false, hasComponent: false)
        await session.waitUntilStopped()
    }

    func activateSkin(_ id: String) {
        activeID = id
        preferences.set(id, forKey: "pet.skin")
        reconcile()
    }

    func setEnabled(_ value: Bool) {
        enabled = value; preferences.set(value, forKey: "pet.enabled"); reconcile()
        onReadinessChange?(session.active)
    }
    func setAudioEnabled(_ value: Bool) {
        audioEnabled = value; preferences.set(value, forKey: "pet.audio"); reconcile()
    }
    func setKeyboardEnabled(_ value: Bool) {
        keyboardEnabled = value; preferences.set(value, forKey: "pet.keyboard"); reconcile()
    }
    func reload() {
        skins = PetCatalog.scan()
        runningSkin = nil
        reconcile()
    }

    private func reconcile() {
        let skin = skins.first { $0.id == activeID }
        let wanted = enabled && hasComponent && skin != nil
        if wanted, let skin {
            if runningSkin != skin.id {
                runningSkin = skin.id
                session.start(skin: skin, audio: audio.channel, keyboard: keyboard.channel, transport: transport)
            }
        } else {
            if runningSkin != nil { session.stop(); runningSkin = nil }
            status = !hasComponent ? "在桌面布局中添加 Miucs 桌宠后启用" : enabled ? "没有可用皮肤" : "已关闭"
        }
        let sound = wanted && connected && audioEnabled && skin?.inputs.contains("audio") == true
        let keys = wanted && connected && keyboardEnabled && skin?.inputs.contains("keyboard") == true
        if sound != audioStarted {
            audioStarted = sound
            audioStart?.cancel()
            if sound {
                audioStart = Task { [weak self] in
                    guard !Task.isCancelled, let self, audioStarted else { return }
                    await audio.start()
                }
            } else { audio.stop() }
        }
        if keys != keyboardStarted {
            keyboardStarted = keys
            keyboardStart?.cancel()
            if keys {
                let request = !preferences.bool(forKey: "pet.keyboardPermissionRequested")
                preferences.set(true, forKey: "pet.keyboardPermissionRequested")
                keyboardStart = Task { [weak self] in
                    guard !Task.isCancelled, let self, keyboardStarted else { return }
                    await keyboard.start(requestAccess: request)
                }
            } else { keyboard.stop() }
        }
    }

    func requestKeyboardAccess() {
        guard keyboardEnabled else { return }
        Task {
            await keyboard.start(requestAccess: true)
            if keyboard.state == .permissionRequired,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func reconnectAudio() {
        guard audioStarted else { return }
        Task { await audio.reconnect() }
    }

    func stop() {
        session.stop()
        audioStart?.cancel(); keyboardStart?.cancel()
        audio.stop(); keyboard.stop()
        audioStarted = false; keyboardStarted = false; runningSkin = nil
    }

    var keyboardLabel: String {
        switch keyboardState {
        case .running: "已连接"
        case .permissionRequired: "需要允许桌屿使用输入监控"
        case .secureInput: "安全输入期间已暂停"
        case .suspended: "锁屏或休眠期间已暂停"
        case .connecting, .recovering: "正在连接…"
        case .stopped: "已暂停"
        }
    }
}

struct PetSettingsView: View {
    @ObservedObject var settings: PetSettings

    var body: some View {
        Form {
            Section {
                Toggle("在小屏上显示桌宠", isOn: Binding(get: { settings.enabled }, set: { settings.setEnabled($0) }))
                Text(settings.status).font(.caption).foregroundStyle(.secondary)
            } header: { Text("Miucs 桌宠") }
            Section("皮肤 · \(settings.layoutName)") {
                Text("皮肤保存在当前编辑的布局中，应用布局后更新小屏。")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(settings.skins) { skin in
                        Button { settings.select(skin.id) } label: {
                            VStack(spacing: 8) {
                                if let url = skin.preview, let image = NSImage(contentsOf: url) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(height: 76)
                                } else {
                                    Image(systemName: "pawprint").font(.largeTitle).frame(height: 76)
                                }
                                HStack(spacing: 5) {
                                    Text(skin.name).lineLimit(1)
                                    if settings.selectedID == skin.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                    }
                                }.font(.callout.weight(.medium))
                            }
                            .frame(maxWidth: .infinity).padding(10)
                            .background(settings.selectedID == skin.id ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.025),
                                        in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                                settings.selectedID == skin.id ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(DeskIsleRowButtonStyle(cornerRadius: 10))
                        .accessibilityLabel(skin.name)
                        .accessibilityAddTraits(settings.selectedID == skin.id ? .isSelected : [])
                    }
                }.padding(.vertical, 6)
                Button("重新读取皮肤") { settings.reload() }
            }
            Section("声音与键盘") {
                Toggle("响应键盘", isOn: Binding(get: { settings.keyboardEnabled }, set: { settings.setKeyboardEnabled($0) }))
                HStack {
                    Text(settings.keyboardLabel).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if settings.keyboardEnabled && settings.keyboardState == .permissionRequired {
                        Button("允许输入监控") { settings.requestKeyboardAccess() }
                    }
                }
                Toggle("跟随系统音频", isOn: Binding(get: { settings.audioEnabled }, set: { settings.setAudioEnabled($0) }))
                if settings.audioEnabled {
                    HStack {
                        Text(settings.audioStatus).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("重新连接") { settings.reconnectAudio() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PetComponentSettings: View {
    @ObservedObject var settings: PetSettings
    var body: some View {
        Picker("皮肤", selection: Binding(get: { settings.selectedID }, set: { settings.select($0) })) {
            ForEach(settings.skins) { Text($0.name).tag($0.id) }
        }
        Text(settings.status).font(.caption).foregroundStyle(.secondary)
    }
}
