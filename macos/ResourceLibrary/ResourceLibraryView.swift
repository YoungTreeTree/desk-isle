import AppKit
import SwiftUI

struct ResourceLibraryPresenter: View {
    @ObservedObject var editor: LayoutEditor
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(item: $editor.resourcePicker) { request in
                ResourceLibraryView(editor: editor, request: request)
            }
    }
}

private enum ResourceFilter: String, CaseIterable { case recent = "最近使用", favorites = "收藏", all = "全部", builtin = "内置" }
private enum ResourceCategory: String, CaseIterable { case all = "全部类型", images = "图片与壁纸", models = "3D 模型" }
private enum ResourceSelection: Hashable { case saved(UUID), wallpaper, model(BuiltInModel3D) }

struct ResourceLibraryView: View {
    @ObservedObject var editor: LayoutEditor
    let request: ResourcePickerRequest
    @State private var entries: [SavedResource] = []
    @State private var sizes: [UUID: Int64] = [:]
    @State private var protectedIDs: Set<UUID> = []
    @State private var filter = ResourceFilter.recent
    @State private var category = ResourceCategory.all
    @State private var selection: ResourceSelection?
    @State private var loading = true
    @State private var working = false
    @State private var error: String?
    @State private var managing = false
    @State private var deleting: SavedResource?
    @State private var cacheGeneration = 0

    private var management: Bool { managing || request.purpose == .manage }
    private var busy: Bool { loading || working || editor.resourceBusy || editor.importingModel }
    private var selected: SavedResource? {
        guard case .saved(let id) = selection else { return nil }
        return entries.first { $0.id == id }
    }
    private var visible: [SavedResource] {
        let matching = entries.filter { entry in
            let accepts: Bool
            if management {
                accepts = category == .all || (category == .models ? entry.kind == .model : entry.kind != .model)
            } else {
                switch request.purpose {
                case .wallpaper: accepts = entry.kind != .model
                case .picture: accepts = entry.kind == .image
                case .model: accepts = entry.kind == .model
                case .manage: accepts = true
                }
            }
            return accepts && (filter != .favorites || entry.favorite)
        }.sorted {
            if filter == .all { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.recentDate == $1.recentDate ? $0.id.uuidString < $1.id.uuidString : $0.recentDate > $1.recentDate
        }
        return filter == .recent ? Array(matching.prefix(24)) : matching
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            toolbar
            Divider()
            if let error {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("重试") { Task { await reload() } }.disabled(busy)
                }.font(.caption).foregroundStyle(.orange).padding(16)
            }
            ScrollView {
                if filter == .builtin { builtins }
                else if visible.isEmpty && !loading {
                    ContentUnavailableView {
                        Label(filter == .favorites ? "还没有收藏" : "留住你喜欢的素材", systemImage: filter == .favorites ? "star" : "photo.on.rectangle.angled")
                    } description: {
                        Text(filter == .favorites ? "点击资源上的星标，下次就能在这里找到。" : "导入图片或 GLB 模型，之后可直接选回来。")
                    }.padding(.top, 64)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 230), spacing: 16)], spacing: 20) {
                        ForEach(visible) { entry in resourceCard(entry) }
                    }.padding(22)
                }
            }
            .overlay { if loading { ProgressView("正在读取我的资源…") } }
            .frame(maxHeight: .infinity)
            Divider()
            selectionDetail
            footer
        }
        .frame(width: 740, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .buttonStyle(DeskIsleButtonStyle())
        .interactiveDismissDisabled(busy)
        .task { editor.notice = ""; await reload() }
        .alert("从我的资源中删除？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除资源", role: .destructive) {
                if let entry = deleting { Task { await delete(entry) } }
                deleting = nil
            }
        } message: { Text("将删除「\(deleting?.name ?? "")」在桌屿中的副本。你原来的文件不受影响。") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled").font(.title2).foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text(management ? "我的资源" : request.title).font(.title2.weight(.semibold))
                Text("导入一次，随时再选。原文件移动后也能继续使用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if request.purpose != .manage {
                Button(managing ? "返回选择" : "管理资源") { managing.toggle(); filter = .recent; selection = nil }
                    .disabled(busy)
            }
        }.padding(22)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Picker("资源范围", selection: $filter) {
                ForEach(ResourceFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 290)
            if management {
                Picker("类型", selection: $category) {
                    ForEach(ResourceCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 125)
            }
            Spacer(minLength: 0)
            if management {
                Menu {
                    Button("导入图片…") { Task { await importFile(model: false) } }
                    Button("导入 GLB 模型…") { Task { await importFile(model: true) } }
                } label: { Label("导入文件", systemImage: "plus") }
            } else {
                Button { Task { await importFile(model: request.purpose == .model) } } label: {
                    Label("导入文件…", systemImage: "plus")
                }
            }
        }.disabled(busy).padding(.horizontal, 22).padding(.bottom, 18)
    }

    private func resourceCard(_ entry: SavedResource) -> some View {
        let chosen = selection == .saved(entry.id)
        let current = editor.currentResourceAsset(for: request).map { entry.assetIDs.contains($0) } ?? false
        return VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                Button { selection = .saved(entry.id) } label: {
                    ZStack(alignment: .bottomLeading) {
                        ResourceThumbnail(entry: entry, store: editor.libraryStore.resources, generation: cacheGeneration)
                            .frame(height: 110).frame(maxWidth: .infinity)
                        if current {
                            Text("当前布局").font(.caption2).padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4)).padding(7)
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(chosen ? Color.accentColor : .clear, lineWidth: 2))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).accessibilityLabel("选择 \(entry.name)")
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                Button { Task { await favorite(entry) } } label: {
                    Image(systemName: entry.favorite ? "star.fill" : "star")
                        .foregroundStyle(entry.favorite ? Color.orange : Color.secondary)
                        .frame(width: 28, height: 28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).padding(6)
                    .help(entry.favorite ? "取消收藏" : "收藏")
                    .accessibilityLabel("\(entry.favorite ? "取消收藏" : "收藏") \(entry.name)")
            }
            Text(entry.name).font(.callout.weight(.medium)).lineLimit(1).help(entry.name)
            Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.disabled(busy)
    }

    private var builtins: some View {
        VStack(alignment: .leading, spacing: 16) {
            if (management && category != .models) || (!management && request.purpose == .wallpaper) {
                HStack(spacing: 16) {
                    Group {
                        if let image = ScreenWallpaper.bundled.portrait?.image {
                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                        } else { Image(systemName: "photo") }
                    }.frame(width: 100, height: 110).clipped().clipShape(RoundedRectangle(cornerRadius: 9))
                    Text("默认壁纸").font(.headline)
                    Spacer()
                    if !management { Button("选择") { selection = .wallpaper } }
                }
            }
            if (management && category != .images) || (!management && request.purpose == .model) {
                ForEach(BuiltInModel3D.allCases) { model in
                    HStack(spacing: 16) {
                        Group {
                            if let url = model.previewURL, let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit() }
                            else { Image(systemName: "cube.transparent").font(.largeTitle) }
                        }.frame(width: 100, height: 130)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(model.title).font(.headline)
                            Text(model.summary).font(.callout).foregroundStyle(.secondary)
                            Text("8 × 12 格 · 含动画").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !management { Button("选择") { selection = .model(model) } }
                    }
                }
            }
            if !management && request.purpose == .picture {
                ContentUnavailableView("暂无内置图片", systemImage: "photo", description: Text("导入自己的图片，或从最近使用中选择。"))
            }
        }.padding(22).disabled(busy)
    }

    @ViewBuilder private var selectionDetail: some View {
        if let entry = selected {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.callout.weight(.medium)).lineLimit(1)
                    let usage = editor.resourceUsage(entry)
                    Text("本机已保存 · \(ByteCountFormatter.string(fromByteCount: sizes[entry.id] ?? 0, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(usage.isEmpty ? (entry.assetIDs.isDisjoint(with: protectedIDs) ? "暂未被布局使用" : "布局恢复备份正在使用") : "用于：\(usage.joined(separator: "、"))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if management {
                    Button("删除资源", role: .destructive) { deleting = entry }
                        .disabled(busy || !entry.assetIDs.isDisjoint(with: protectedIDs) || error != nil)
                        .help("正在被布局、小屏画面或恢复备份使用的素材不能删除")
                }
            }.padding(.horizontal, 22).padding(.vertical, 14)
                .background(Color.primary.opacity(0.03))
        } else if selection != nil {
            Text(selection == .wallpaper ? "已选择：默认壁纸" : "已选择：\(BuiltInModel3D.bb8.title)")
                .font(.callout).padding(.horizontal, 22).padding(.vertical, 14)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                if management {
                    Text("\(entries.count) 项资源 · \(ByteCountFormatter.string(fromByteCount: sizes.values.reduce(0, +), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("打开存储目录") { NSWorkspace.shared.open(editor.libraryStore.root) }
                        Button("清理缩略图缓存") { Task { await clearCache() } }.disabled(busy)
                    }.font(.caption)
                } else {
                    Text("选择后保存到当前布局，点击「应用到小屏」生效。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !editor.notice.isEmpty { Text(editor.notice).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
            if busy { ProgressView().controlSize(.small) }
            Button(management ? "完成" : "取消") { editor.resourcePicker = nil }.keyboardShortcut(.cancelAction).disabled(busy)
            if !management {
                Button(request.purpose == .picture && request.componentID == nil ? "添加到布局" : "使用所选资源") { Task { await useSelected() } }
                    .buttonStyle(DeskIsleButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(busy || selection == nil || error != nil)
            }
        }.padding(22)
    }

    private func reload(select id: UUID? = nil) async {
        loading = true
        defer { loading = false }
        do {
            let store = editor.libraryStore.resources
            let result = try await Task.detached(priority: .utility) {
                let entries = try store.load().entries
                return (entries, Dictionary(uniqueKeysWithValues: entries.map { ($0.id, store.size(of: $0)) }))
            }.value
            entries = result.0; sizes = result.1
            protectedIDs = try editor.protectedResourceIDs()
            error = nil
            if let id { selection = .saved(id) }
            else if selection == nil, let asset = editor.currentResourceAsset(for: request), let entry = entries.first(where: { $0.assetIDs.contains(asset) }) {
                selection = .saved(entry.id)
            }
            if case .saved(let id) = selection, !entries.contains(where: { $0.id == id }) { selection = nil }
        } catch { self.error = error.localizedDescription }
    }

    private func importFile(model: Bool) async {
        if let id = await editor.importResource(for: request, model: model) {
            filter = .recent; category = .all
            await reload(select: id)
        }
    }

    private func favorite(_ entry: SavedResource) async {
        working = true
        defer { working = false }
        do {
            let store = editor.libraryStore.resources
            try await Task.detached(priority: .utility) { try store.setFavorite(!entry.favorite, id: entry.id) }.value
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    private func delete(_ entry: SavedResource) async {
        working = true
        defer { working = false }
        do {
            guard editor.flushLayoutSave() else { throw LayoutLibraryError.message(editor.libraryError ?? "布局保存失败") }
            let protected = try editor.protectedResourceIDs(), store = editor.libraryStore.resources
            try await Task.detached(priority: .utility) { try store.delete(entry.id, protecting: protected) }.value
            selection = nil
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    private func clearCache() async {
        working = true
        defer { working = false }
        do {
            let store = editor.libraryStore.resources
            try await Task.detached(priority: .utility) { try store.clearThumbnailCache() }.value
            cacheGeneration += 1
            editor.notice = "缩略图缓存已清理，原始素材和收藏已保留。"
        } catch { self.error = error.localizedDescription }
    }

    private func useSelected() async {
        switch selection {
        case .saved:
            if let selected { await editor.useResource(selected, for: request) }
        case .wallpaper:
            guard request.layoutID == editor.library.editingID else { error = "布局已切换，请重新打开选择器。"; return }
            editor.restoreDefaultWallpaper()
            if editor.flushLayoutSave() { editor.resourcePicker = nil }
        case .model(let model):
            guard request.layoutID == editor.library.editingID else { error = "布局已切换，请重新打开选择器。"; return }
            await editor.useBuiltInModel3D(model)
        case nil: break
        }
    }
}
