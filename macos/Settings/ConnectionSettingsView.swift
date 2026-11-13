import AppKit
import SwiftUI

struct ConnectionSettingsView: View {
    @ObservedObject var editor: LayoutEditor
    @ObservedObject var settings: ConnectionSettings
    let showLayout: () -> Void
    @State private var selected: BuiltInPlugin = .garmin
    @State private var showingGuide = false
    @State private var hookAction: Bool?

    var body: some View {
        VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("插件配置").font(.title2.weight(.semibold))
                        Text("管理账号、数据来源与插件偏好。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("使用向导") { showingGuide = true }
                }.padding(22)
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 232)
                Divider()
                Group {
                    if selected == .pet {
                        PetSettingsView(settings: editor.petSettings)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                if let error = settings.persistenceError { Text(error).foregroundStyle(.orange) }
                                switch selected {
                                case .garmin:
                                    GarminAccountView(editor: editor, settings: settings, login: settings.garminLogin)
                                case .codex: codexCard
                                case .notifications: notificationCard
                                case .macLoad, .bluetooth, .pictures, .model3D:
                                    LocalPluginView(plugin: selected, settings: settings.localPlugins,
                                                    editor: editor, showLayout: showLayout)
                                case .pet: EmptyView()
                                }
                            }.frame(maxWidth: 850, alignment: .leading).padding(24)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .buttonStyle(DeskIsleButtonStyle())
        .disclosureGroupStyle(DeskIsleDisclosureStyle())
        .onAppear { settings.inspectHooks(); if !settings.profile.setupComplete { showingGuide = true } }
        .sheet(isPresented: $showingGuide) {
            guide.padding(24).frame(width: 620).buttonStyle(DeskIsleButtonStyle())
        }
        .alert(hookAction == true ? "断开 Codex 通知？" : "连接 Codex 通知？",
               isPresented: Binding(get: { hookAction != nil }, set: { if !$0 { hookAction = nil } })) {
            let remove = hookAction == true
            Button("取消", role: .cancel) { hookAction = nil }
            Button(remove ? "断开连接" : "连接通知", role: remove ? .destructive : nil) {
                settings.configureHooks(remove: remove); hookAction = nil
            }
        } message: {
            Text("桌屿将备份并更新所选 Codex 目录中的 hooks.json，只调整自己的条目。连接后仍需在 Codex 中审核并信任。")
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                Text("内置插件 · \(BuiltInPlugin.allCases.count)")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 10)
                ForEach(BuiltInPlugin.allCases) { plugin in
                    Button { selected = plugin } label: {
                        HStack(spacing: 11) {
                            Image(systemName: plugin.symbol).font(.system(size: 19)).frame(width: 25)
                                .foregroundStyle(selected == plugin ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(plugin.title).font(.callout.weight(selected == plugin ? .semibold : .medium))
                                Text(plugin.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 10).padding(.vertical, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selected == plugin ? Color.accentColor.opacity(0.10) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }.buttonStyle(DeskIsleRowButtonStyle()).accessibilityLabel(plugin.title)
                        .accessibilityAddTraits(selected == plugin ? .isSelected : [])
                }
                Divider().padding(.vertical, 10)
                Text("组件的尺寸和摆放位置，\n在桌面布局中调整。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            }.padding(14)
        }
    }

    private var guide: some View {
        card {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                Text("开始使用桌屿").font(.headline)
                Spacer()
                Text("账号连接可以稍后再做").font(.caption).foregroundStyle(.secondary)
            }
            guideRow("1", "连接小屏", editor.connected ? "小屏已连接，可开始排列组件。" : "原生 USB 或 CH343 接一根线即可；未连接时也能查看布局。")
            guideRow("2", "选择组件", "电脑负载、蓝牙电量和图片不需要账号。Codex 与佳明按需启用。")
            guideRow("3", "按需授权桌宠", "在插件配置的 Miucs 桌宠中开启键盘或音频响应时，才申请对应的系统权限。")
            HStack {
                Button("桌宠与权限") { showingGuide = false; selected = .pet }
                Spacer()
                Button(settings.profile.setupComplete ? "收起向导" : "开始排列组件") {
                    let isFirst = !settings.profile.setupComplete
                    settings.completeSetup(); showingGuide = false
                    if isFirst { showLayout() }
                }.buttonStyle(DeskIsleButtonStyle(prominent: true))
            }
        }
    }

    private var codexCard: some View {
        card {
            HStack {
                heading("Codex 用量", symbol: "terminal", subtitle: "订阅额度与今日 Token")
                Spacer()
                Toggle("启用 Codex 用量", isOn: Binding(get: { settings.profile.codex.enabled },
                    set: { enabled in settings.updateCodex { $0.enabled = enabled } }))
                    .labelsHidden().toggleStyle(.switch)
            }
            status(settings.codexStatus)
            HStack {
                Button("检查 Codex 连接") { editor.checkCodexConnection() }
                    .disabled(!settings.profile.codex.enabled || settings.codexStatus.kind == .checking)
                if let application = codexApplication {
                    Button("打开 Codex") { NSWorkspace.shared.open(application) }
                }
                Spacer()
                Text("每 3 分钟更新").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("高级设置") {
                VStack(alignment: .leading, spacing: 12) {
                    pathRow("Codex 程序", path: settings.profile.codex.executable ?? "自动发现已安装的 Codex") {
                        choose(directory: false) { url in
                            let program = url.pathExtension == "app" ? url.appendingPathComponent("Contents/Resources/codex") : url
                            settings.updateCodex { $0.executable = program.path }
                        }
                    }
                    if settings.profile.codex.executable != nil {
                        Button("恢复自动发现") { settings.updateCodex { $0.executable = nil } }.font(.caption)
                    }
                    pathRow("Codex 数据目录", path: settings.profile.codex.homeURL().path) {
                        choose(directory: true) { url in settings.updateCodex { $0.home = url.path }; settings.inspectHooks() }
                    }
                    if settings.profile.codex.home != nil {
                        Button("使用默认数据目录") { settings.updateCodex { $0.home = nil }; settings.inspectHooks() }.font(.caption)
                    }
                    Text("所选目录同时用于账号读取、本机用量统计和通知接入。切换目录后会清空旧账号的显示数据。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 10)
            }
        }
    }

    private var notificationCard: some View {
        card {
            heading("Codex 通知", symbol: "bell.badge", subtitle: "让通知岛跟随 Agent 任务更新")
            status(settings.hooksStatus)
            HStack {
                Button(settings.hookOperation ? "正在更新…" : "连接 / 修复通知") { hookAction = false }
                Button("检查通知配置") { settings.inspectHooks() }
                Button("测试通知岛") { editor.testNotification() }
                Spacer()
                if settings.hooksStatus.kind == .ready || settings.hooksStatus.kind == .partial {
                    Button("断开", role: .destructive) { hookAction = true }
                }
            }.disabled(settings.hookOperation)
            Text("其他应用也可通过 deskisle 命令或本地 JSON 事件接入，不需要 Codex 账号。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
    private func heading(_ title: String, symbol: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func status(_ value: ConnectionStatus) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(value.kind == .ready ? Color.green : value.kind == .unavailable ? Color.orange : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(value.title).font(.callout.weight(.medium))
            }
            Text(value.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func guideRow(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.weight(.semibold)).frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func pathRow(_ title: String, path: String, select: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.medium))
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("选择…", action: select)
        }
    }
    private func choose(directory: Bool, selected: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url { selected(url) }
    }
    private var codexApplication: URL? {
        guard var url = settings.profile.codex.executableURL() else { return nil }
        while url.path != "/" {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
