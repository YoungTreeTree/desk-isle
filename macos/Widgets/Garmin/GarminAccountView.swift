import AppKit
import SwiftUI

struct GarminAccountView: View {
    @ObservedObject var editor: LayoutEditor
    @ObservedObject var settings: ConnectionSettings
    @ObservedObject var login: GarminLogin
    @State private var showingLogin = false
    @State private var showingDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 13) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 26)).foregroundStyle(.teal)
                    .frame(width: 50, height: 50).background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text("佳明健康").font(.title2.weight(.semibold))
                    Text("佳明中国区 · 步数、睡眠与身体状态").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("启用佳明健康", isOn: Binding(get: { settings.profile.garmin.enabled },
                    set: { value in settings.updateGarmin { $0.enabled = value } }))
                    .labelsHidden().toggleStyle(.switch)
            }
            VStack(alignment: .leading, spacing: 16) {
                Label(settings.profile.garmin.hasSavedSession ? "登录会话由桌屿保管" : "连接你的佳明账号",
                      systemImage: settings.profile.garmin.hasSavedSession ? "checkmark.shield" : "person.crop.circle")
                    .font(.headline)
                HStack(spacing: 7) {
                    Circle().fill(settings.garminStatus.kind == .ready ? Color.green : Color.secondary).frame(width: 6, height: 6)
                    Text(settings.garminStatus.title).font(.callout.weight(.medium))
                }
                Text(settings.garminStatus.detail).foregroundStyle(.secondary).font(.callout)
                if let notice = settings.garminSessionNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(settings.profile.garmin.hasSavedSession ? "重新登录" : "登录佳明中国区") { showingLogin = true }
                        .buttonStyle(DeskIsleButtonStyle(prominent: true))
                    Button("检查连接") { editor.checkGarminConnection() }
                        .disabled(!settings.profile.garmin.enabled || !settings.profile.garmin.hasSavedSession || settings.garminStatus.kind == .checking)
                    Spacer()
                    if settings.profile.garmin.sessionID != nil {
                        Button("退出账号", role: .destructive) { showingDisconnect = true }
                    }
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
            VStack(alignment: .leading, spacing: 9) {
                Label("仅在这台 Mac 保存", systemImage: "lock.shield").font(.callout.weight(.medium))
                Text("会话仅供当前 Mac 用户读取，密码不会保存。会话更新由桌屿处理，失效时会提示重新登录。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("每 10 分钟更新健康摘要；小屏仅接收展示数据。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            DisclosureGroup("迁移已有会话") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("可从 garmin-mcp-cn 的中国区登录目录导入一次。桌屿保存独立副本，原文件不会改动。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("导入已有会话…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true; panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
                        panel.prompt = "导入会话"
                        if panel.runModal() == .OK, let directory = panel.url { settings.importGarminSession(directory) }
                    }
                }.padding(.top, 10)
            }
        }
        .sheet(isPresented: $showingLogin) { GarminSignInView(settings: settings, login: login) }
        .alert("退出佳明账号？", isPresented: $showingDisconnect) {
            Button("取消", role: .cancel) {}
            Button("退出并清除会话", role: .destructive) { settings.disconnectGarmin() }
        } message: { Text("将停止读取佳明数据，并清除桌屿保存的登录会话。导入前的原始文件不受影响。") }
    }
}

private struct GarminSignInView: View {
    @ObservedObject var settings: ConnectionSettings
    @ObservedObject var login: GarminLogin
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("登录佳明中国区").font(.title2.weight(.semibold))
            Text("登录信息会用于连接佳明中国区服务。成功后，桌屿保存会话，不保存密码。")
                .font(.callout).foregroundStyle(.secondary)
            if login.state == .complete {
                Label("账号已连接", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
            } else if login.state == .verification {
                TextField("验证码", text: $code).textFieldStyle(.roundedBorder).onSubmit { submitCode() }
            } else {
                TextField("佳明账号（邮箱）", text: $email).textFieldStyle(.roundedBorder)
                    .disabled(login.busy)
                SecureField("密码", text: $password).textFieldStyle(.roundedBorder)
                    .disabled(login.busy).onSubmit { submit() }
            }
            if !login.message.isEmpty {
                HStack(spacing: 9) {
                    if login.state == .signingIn { ProgressView().controlSize(.small) }
                    Text(login.message).font(.callout).foregroundStyle(login.state == .failed ? Color.orange : .secondary)
                }
            }
            HStack {
                Button(login.state == .complete ? "完成" : "取消") { dismiss() }
                Spacer()
                if login.state == .verification {
                    Button("验证") { submitCode() }.buttonStyle(DeskIsleButtonStyle(prominent: true)).disabled(code.isEmpty)
                } else if login.state != .complete {
                    Button("登录") { submit() }.buttonStyle(DeskIsleButtonStyle(prominent: true))
                        .disabled(login.busy || email.isEmpty || password.isEmpty)
                }
            }
        }.padding(28).frame(width: 440)
            .buttonStyle(DeskIsleButtonStyle())
            .onAppear { login.cancel() }
            .onDisappear { password = ""; code = ""; login.cancel() }
    }
    private func submit() {
        guard !login.busy, !email.isEmpty, !password.isEmpty else { return }
        settings.signInGarmin(email: email, password: password)
        password = ""
    }
    private func submitCode() { login.verify(code); code = "" }
}

struct LocalPluginView: View {
    let plugin: BuiltInPlugin
    @ObservedObject var settings: LocalPluginSettings
    @ObservedObject var editor: LayoutEditor
    let showLayout: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label(plugin.title, systemImage: plugin.symbol).font(.title2.weight(.semibold))
            Text(plugin.summary).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 18) {
                Label("使用本机数据，无需账号", systemImage: "checkmark.circle").font(.headline)
                switch plugin {
                case .macLoad:
                    Picker("刷新间隔", selection: Binding(get: { settings.macInterval }, set: { settings.setMacInterval($0) })) {
                        ForEach([4, 8, 16], id: \.self) { Text("约 \($0) 秒").tag($0) }
                    }.frame(maxWidth: 300)
                    Text("显示 CPU、GPU、内存与进程负载。CPU 温度目前适配 M4 系列；温度和功耗无可用读数时显示 —。")
                        .font(.callout).foregroundStyle(.secondary)
                case .bluetooth:
                    Picker("刷新间隔", selection: Binding(get: { settings.bluetoothInterval }, set: { settings.setBluetoothInterval($0) })) {
                        ForEach([30, 60, 120], id: \.self) { Text("约 \($0) 秒").tag($0) }
                    }.frame(maxWidth: 300)
                    Text("从 macOS 读取已连接配件的电量。是否能显示电量取决于配件提供的信息。")
                        .font(.callout).foregroundStyle(.secondary)
                case .pictures:
                    Text("导入的图片和 GIF 会保存到桌屿。每张图片的尺寸、位置和显示方式可分别在桌面布局中调整。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("导入图片或 GIF…") { editor.choosePicture(); showLayout() }
                default: EmptyView()
                }
                Button("前往桌面布局") { showLayout() }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
        }
    }
}
