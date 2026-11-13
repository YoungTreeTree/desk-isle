import SwiftUI

struct LayoutLibraryPage: View {
    @ObservedObject var editor: LayoutEditor
    let showConnections: () -> Void
    @State private var renaming: UUID?
    @State private var name = ""
    @State private var deleting: UUID?

    var body: some View {
        Group {
            if editor.showingLibrary {
                library
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Button { editor.returnToLibrary() } label: {
                            Label("布局库", systemImage: "chevron.left")
                        }
                        Text(editor.editingProfile?.name ?? "布局").font(.headline)
                        Text(editor.loadingLayout ? "正在读取…" : "修改自动保存到 Mac")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let id = editor.library.editingID {
                            Button("重命名") { beginRename(id) }
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 10)
                    errorBanner
                    Divider()
                    LayoutPage(editor: editor, showConnections: showConnections)
                        .disabled(editor.loadingLayout)
                }
            }
        }
        .buttonStyle(DeskIsleButtonStyle())
        .sheet(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            VStack(alignment: .leading, spacing: 18) {
                Text("布局名称").font(.headline)
                TextField("名称", text: $name).onSubmit { finishRename() }
                HStack {
                    Spacer()
                    Button("取消") { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("保存") { finishRename() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 340)
        }
        .alert("删除这个布局？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let id = deleting { Task { await editor.deleteLayout(id) } }
                deleting = nil
            }
        } message: { Text("其他布局和当前小屏画面不受影响。") }
        .onDisappear { editor.flushLayoutSave() }
    }

    private var library: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("我的布局").font(.title2.weight(.semibold))
                    Text("为不同场景留一套桌面。点击布局即可切换小屏。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await editor.createLayout() } } label: {
                    Label("新建布局", systemImage: "plus")
                }.buttonStyle(DeskIsleButtonStyle(prominent: true))
                    .disabled(editor.libraryBusy || editor.loadingLayout)
            }.padding(24)
            errorBanner
            if editor.syncPending || editor.applying {
                HStack {
                    Image(systemName: editor.applying ? "arrow.triangle.2.circlepath" : "exclamationmark.circle")
                    Text(editor.applying ? "正在切换小屏…" : editor.notice.isEmpty ? "布局等待同步到小屏" : editor.notice)
                        .lineLimit(2)
                    Spacer()
                    if editor.connected && !editor.applying {
                        Button("重试同步") { Task { await editor.synchronizeRequestedScene() } }
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 12)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 20)], spacing: 20) {
                    ForEach(editor.library.layouts) { profile in
                        layoutCard(profile)
                    }
                }.padding(.horizontal, 24).padding(.bottom, 24)
                if editor.library.layouts.isEmpty {
                    ContentUnavailableView {
                        Label("留住你喜欢的桌面", systemImage: "rectangle.3.group")
                    } description: {
                        Text("连接小屏后会自动保存现有画面，也可以先新建一套布局。")
                    }
                    .padding(.top, 60)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private var errorBanner: some View {
        if let message = editor.libraryError {
            HStack {
                Label(message, systemImage: "exclamationmark.triangle")
                Spacer()
                if !editor.libraryReadFailed { Button("重试保存") { editor.flushLayoutSave() } }
            }.font(.caption).foregroundStyle(.orange).padding(.horizontal, 24).padding(.vertical, 8)
        }
    }

    private func layoutCard(_ profile: SavedLayout) -> some View {
        let active = editor.library.displayed?.id == profile.id && editor.deviceReady
        let pending = editor.library.requested?.id == profile.id && (editor.syncPending || editor.applying)
        return VStack(alignment: .leading, spacing: 0) {
            Button { Task { await editor.selectLayout(profile.id) } } label: {
                VStack(alignment: .leading, spacing: 14) {
                    LayoutThumbnail(profile: profile, store: editor.libraryStore,
                                    skinURL: editor.petSettings.skins.first { $0.id == profile.scene.skinID }?.preview)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    HStack {
                        Text(profile.name).font(.headline).lineLimit(1)
                        Spacer()
                        if pending { badge("待同步", color: .orange) }
                        else if active { badge("正在使用", color: .accentColor) }
                    }
                    Text("\(profile.scene.layout.direction.title) · \(profile.scene.layout.components.count) 个组件")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(14).contentShape(Rectangle())
            }.buttonStyle(DeskIsleRowButtonStyle(cornerRadius: 12))
                .disabled(editor.libraryBusy)
                .accessibilityLabel("使用布局 \(profile.name)")
            HStack {
                if active && editor.library.displayed?.scene != profile.scene {
                    Text("有改动待应用").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("复制布局") { Task { await editor.createLayout(copying: profile.id) } }
                    Button("重命名") { beginRename(profile.id) }
                    Button("删除布局", role: .destructive) { deleting = profile.id }
                        .disabled(!editor.library.canDelete(profile.id))
                } label: { Image(systemName: "ellipsis").frame(width: 22) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("\(profile.name) 的操作")
                    .disabled(editor.libraryBusy || editor.loadingLayout)
            }.padding(.horizontal, 16).padding(.bottom, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(active ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08)))
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.09), in: Capsule())
    }

    private func beginRename(_ id: UUID) {
        name = editor.library.layouts.first { $0.id == id }?.name ?? ""
        renaming = id
    }

    private func finishRename() {
        if let id = renaming { editor.renameLayout(id, to: name) }
        renaming = nil
    }
}
