import AppKit
import SwiftUI


struct LayoutPage: View {
    @ObservedObject var editor: LayoutEditor
    let showConnections: () -> Void
    @State private var previewActivity = PreviewActivity.hidden

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScreenPreview(editor: editor, activity: previewActivity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                ScrollView {
                    inspector
                        .padding(20)
                }
                .frame(width: 320)
            }
            Divider()
            footer
        }
        .background(PreviewWindowProbe(activity: $previewActivity).allowsHitTesting(false))
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("屏幕方向").font(.headline)
                Picker("屏幕方向", selection: Binding(get: { editor.draft.direction }, set: { editor.changeDirection($0) })) {
                    ForEach(ScreenDirection.allCases) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text("按小屏实际摆放的方向选择。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("组件").font(.headline)
                    Spacer()
                    Menu {
                        ForEach(WidgetRegistry.menu) { kind in
                            Button(WidgetRegistry.definition(for: kind).addTitle) { editor.add(kind) }
                                .disabled(!editor.canAdd(kind))
                        }
                        Button("添加自定义组件") { editor.addPlaceholder() }
                        Button("添加 Miucs 桌宠") { editor.add(.pet) }
                            .disabled(!editor.canAdd(.pet))
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .fixedSize()
                    .disabled(!editor.canAdd)
                }
                if editor.draft.components.isEmpty {
                    Text("当前只显示壁纸。").foregroundStyle(.secondary)
                }
                ForEach(editor.draft.components.reversed()) { component in
                    Button {
                        editor.selectedID = component.id
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: component.symbol)
                                .frame(width: 16)
                            Text(component.isPicture ? editor.pictures[component.id]?.name ?? component.name : component.name)
                                .lineLimit(1)
                            Spacer()
                            Text(component.footprint.label)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(component.id == editor.selectedID ? Color.accentColor.opacity(0.15) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            if let component = editor.selected {
                Divider()
                componentInspector(component)
            }
        }
        .disabled(editor.applying || editor.importingPicture || editor.importingWallpaper)
    }

    private func componentInspector(_ component: Component) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(component.name).font(.headline)
            HStack(spacing: 12) {
                positionField("列", value: Binding(get: { component.position.column + 1 }, set: {
                    editor.move(component.id, to: GridPosition(column: max(1, $0) - 1, row: component.position.row))
                }))
                positionField("行", value: Binding(get: { component.position.row + 1 }, set: {
                    editor.move(component.id, to: GridPosition(column: component.position.column, row: max(1, $0) - 1))
                }))
            }
            let presets = component.sizePresets
            if !presets.isEmpty {
                let supported = presets.filter { editor.draft.grid.contains($0.footprint) }
                let choices = supported.contains { $0.footprint == component.footprint }
                    ? supported : [ComponentSizePreset(component.footprint)] + supported
                Picker("占格尺寸", selection: Binding(get: { component.footprint }, set: { editor.resize(component, to: $0) })) {
                    ForEach(choices, id: \.footprint) { preset in
                        Text(preset.label).tag(preset.footprint)
                    }
                }
            }
            if component.isModel3D {
                Model3DSettings(editor:editor)
            } else if component.isPet {
                PetComponentSettings(settings: editor.petSettings)
                Text("占 \(component.footprint.label)，桌宠画面居中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if component.isGarmin {
                Text("占 \(component.footprint.label)，每 10 分钟读取 Garmin Connect")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = editor.garminDisplayNotice ?? editor.garminContent.error?.rawValue {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if component.isCodex {
                Text("占 \(component.footprint.label)，每 3 分钟更新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = editor.codexDisplayNotice {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } else if component.isBluetooth {
                Text("占 \(component.footprint.label)，刷新间隔可在插件配置中调整")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = editor.bluetoothDisplayNotice {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } else if component.isMacLoad {
                Text(editor.macLoadDisplayNotice ?? "Miucs 和桌屿的 CPU 占用按单核计。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if component.isPicture {
                if let picture = editor.pictures[component.id] {
                    Text(picture.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let message = editor.pictureDisplayNotices[component.id] {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if editor.picturePlaysOnBoard(component) {
                    Label("小屏独立播放", systemImage: "play.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(editor.pictures[component.id] == nil ? "选取图片" : "更换图片") {
                    editor.choosePicture(replacing: component.id)
                }
            } else if component.isNotifications {
                Text(editor.notificationListenError ?? editor.notificationDisplayNotice ??
                     editor.notificationSnapshot.item?.style.label ?? "等待本地通知")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("测试通知") { editor.testNotification() }
                    if let url = editor.codexSessionURL {
                        Button("打开 Codex 会话") { NSWorkspace.shared.open(url) }
                    }
                }
            } else {
                Text("自定义组件可先留出位置，接入内容后显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if component.isGarmin || component.isCodex || component.isNotifications {
                Button("打开插件配置") { showConnections() }.controlSize(.small)
            }
            HStack {
                Button("上移一层") { editor.reorder(component.id, by: 1) }
                    .disabled(editor.draft.components.last?.id == component.id)
                Button("下移一层") { editor.reorder(component.id, by: -1) }
                    .disabled(editor.draft.components.first?.id == component.id)
                Spacer()
                Button("移除", role: .destructive) { editor.remove(component.id) }
            }
            .controlSize(.small)
        }
        .id(component.id)
    }

    private func positionField(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.grouping(.never))
                .labelsHidden()
                .monospacedDigit()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            let wallpaperMessage = editor.importingWallpaper ? "正在准备壁纸…" : editor.wallpaperNotice
            let message = !editor.draft.isValid ? "当前组件尺寸超出小屏支持的范围。" :
                editor.libraryError ?? (!editor.notice.isEmpty ? editor.notice :
                wallpaperMessage ?? (editor.connected ?
                    (editor.hasChanges || editor.unsaved ? "有改动待应用" : "拖动组件，松手对齐网格") :
                    "修改已保存到 Mac，可在连接后应用"))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("恢复默认") { editor.reset() }
                .disabled(editor.applying || editor.importingPicture || editor.importingWallpaper)
            Button(editor.applying ? "正在应用…" : editor.connected ? "应用到小屏" : "连接后应用") {
                Task { await editor.apply() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!editor.canApply)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }
}
