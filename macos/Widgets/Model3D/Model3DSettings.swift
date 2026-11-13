import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension LayoutEditor {
    func chooseModel3D() {
        guard !applying,!libraryBusy,!loadingLayout,draft.model3D != nil || canAdd(.model3D) else { return }
        notice=""
        resourcePicker = ResourcePickerRequest(purpose: .model, layoutID: library.editingID)
    }

    func useBuiltInModel3D(_ model: BuiltInModel3D) async {
        guard !applying,!libraryBusy,!loadingLayout,draft.model3D != nil || canAdd(.model3D) else { return }
        let editingID=library.editingID
        importingModel=true
        defer { importingModel=false }
        notice="正在准备 \(model.title)…"
        do {
            let file=try await Task.detached(priority:.userInitiated){ try model.load() }.value
            guard editingID == library.editingID else { throw Model3DError.invalid("布局已切换，请在当前布局重新选择模型。") }
            try importModel3D(file)
            if flushLayoutSave() {
                resourcePicker=nil
                notice="模型已保存到 Mac，点击应用后上传到小屏。"
            } else { notice=libraryError ?? "布局保存失败，请重试。" }
        } catch { notice=error.localizedDescription }
    }
    func importModel3D(_ file: Model3DFile, storedID: UUID? = nil) throws {
        guard draft.model3D != nil || canAdd(.model3D) else { throw Model3DError.invalid("当前布局无法添加 3D 组件。") }
        let resourceID = try storedID ?? libraryStore.storeModel(file)
        try libraryStore.resources.recordUse(of: resourceID)
        draftModelID=resourceID;modelName=file.name
        modelOptimized=file.quality == .smooth;modelTriangles=file.triangles;modelSourceTriangles=file.sourceTriangles ?? file.triangles
        modelStats=nil
        if draft.model3D == nil {
            guard let component=WidgetRegistry.model3D.makeComponent(in:draft) else { throw Model3DError.invalid("当前布局放不下 8 × 12 格的 3D 组件。") }
            draft.components.append(component)
        } else { recordDraftChange() }
        selectedID=Component.model3DID
    }
    func changeModelDetail() {
        guard !applying,!libraryBusy,!loadingLayout,let id=draftModelID else { return }
        let editingID = library.editingID
        let store=libraryStore, quality:Model3DQuality=modelOptimized ? .original : .smooth
        importingModel=true
        notice=quality == .smooth ? "正在生成流畅版，保留原文件和动画…" : "正在恢复原始模型细节…"
        Task {
            defer { importingModel=false }
            do {
                let file=try await Task.detached(priority:.userInitiated){
                    let original=try store.model(id)
                    return try Model3DFile(source:original.source,name:original.name,quality:quality)
                }.value
                guard editingID == library.editingID, draftModelID == id else {
                    throw Model3DError.invalid("布局或模型已切换，请在当前布局重试。")
                }
                try importModel3D(file)
                modelStats=nil
                notice="模型已保存到 Mac，点击应用后上传到小屏。"
            } catch { notice=error.localizedDescription }
        }
    }
    func readModelStatistics() async {
        do { modelStats=try await usb.model3DStatistics() }
        catch { notice=error.localizedDescription }
    }
    func replayModel() async {
        do { try await usb.model3DControl(1);modelStats=nil }
        catch { notice=error.localizedDescription }
    }
}

struct Model3DSettings: View {
    @ObservedObject var editor: LayoutEditor
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(editor.modelName ?? "尚未选取模型").font(.callout.weight(.medium))
            Text("透明背景 · 模型连接后上传，由小屏实时绘制")
                .font(.caption).foregroundStyle(.secondary)
            Button(editor.draftModelID == nil ? "选择模型…" : "更换模型…"){editor.chooseModel3D()}
                .disabled(editor.importingModel || editor.applying)
            if let count=editor.modelTriangles {
                Text("\(editor.modelOptimized ? "流畅版" : "原始细节") · \(count.formatted()) 三角面")
                    .font(.caption).foregroundStyle(.secondary)
                Button(editor.modelOptimized ? "恢复原始细节" : "生成流畅版"){editor.changeModelDetail()}
                    .disabled(editor.importingModel || editor.applying)
                Text("保留原文件、贴图和动画。切换后点击应用生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("渲染精度",selection:Binding(get:{editor.draftModelScale},set:{editor.draftModelScale=$0;editor.recordDraftChange()})){
                Text("原生分辨率").tag(1)
                Text("半分辨率").tag(2)
                Text("四分之一分辨率").tag(4)
            }
            Text("降低精度可提高流畅度，占格尺寸不变；点击应用后生效。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("重播出场"){Task{await editor.replayModel()}}
                Button("读取性能"){Task{await editor.readModelStatistics()}}
            }.disabled(!editor.connected || editor.applying || editor.library.displayed?.id != editor.library.editingID || editor.applied.model3D == nil)
            if let stats=editor.modelStats {
                VStack(alignment:.leading,spacing:5){
                    Text("\(stats.width) × \(stats.height) · \(stats.triangles.formatted()) 三角面")
                    Text(String(format:"显示 %.1f FPS · 绘制平均 %.1f ms",stats.fps,stats.averageTime))
                    Text(String(format:"最长 %.1f ms · 绘制耗时占比 %.0f%%",stats.maxTime,stats.renderOccupancy))
                    Text(String(format:"PSRAM 可用 %.1f MiB · 最大连续 %.1f MiB",Double(stats.freePSRAM)/1048576,Double(stats.largestPSRAM)/1048576))
                    Text("已绘制 \(stats.frames) 帧，统计自本次应用或重播起。")
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}
