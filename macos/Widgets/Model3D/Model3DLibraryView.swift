import AppKit
import SwiftUI

// Observe presentation separately so opening the picker does not subscribe the window shell
// to every layout/runtime update. Catalog thumbnails are static PNGs, not live renderers.
struct Model3DLibraryPresenter: View {
    @ObservedObject var editor: LayoutEditor
    var body: some View {
        Color.clear.frame(width:0,height:0)
            .sheet(isPresented:$editor.showingModelLibrary) { Model3DLibraryView(editor:editor) }
    }
}

struct Model3DLibraryView: View {
    @ObservedObject var editor: LayoutEditor

    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text("选择 3D 模型").font(.title2.bold())
                    Text("选一个内置模型，或导入自己的 GLB 文件。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { editor.showingModelLibrary=false } label: {
                    Image(systemName:"xmark").frame(width:20,height:20)
                }
                .buttonStyle(.borderless)
                .help("关闭")
                .accessibilityLabel("关闭模型选择")
                .keyboardShortcut(.cancelAction)
                .disabled(editor.importingModel)
            }
            Text("内置模型").font(.headline)
            ForEach(BuiltInModel3D.allCases) { model in
                HStack(spacing:24) {
                    Group {
                        if let url=model.previewURL,let image=NSImage(contentsOf:url) {
                            Image(nsImage:image).resizable().scaledToFit()
                        } else {
                            Image(systemName:"cube.transparent").font(.system(size:48)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width:140,height:176)
                    .accessibilityHidden(true)
                    VStack(alignment:.leading,spacing:10) {
                        Text(model.title).font(.title3.bold())
                        Text(model.summary).foregroundStyle(.secondary)
                        Text("8 × 12 格 · 透明背景").font(.caption).foregroundStyle(.secondary)
                        Button("使用 \(model.title)") { Task { await editor.useBuiltInModel3D(model) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(editor.importingModel)
                    }
                    Spacer(minLength:0)
                }
                .padding(18)
                .background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:14))
            }
            Divider()
            HStack(spacing:14) {
                Image(systemName:"square.and.arrow.down").font(.title2).foregroundStyle(.secondary)
                VStack(alignment:.leading,spacing:4) {
                    Text("自定义模型").font(.headline)
                    Text("支持 .glb 文件，保留模型内的动画。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("导入 GLB…") { editor.chooseCustomModel3D() }
                    .disabled(editor.importingModel)
            }
            if editor.importingModel {
                HStack(spacing:8) {
                    ProgressView().controlSize(.small)
                    Text("正在准备模型…").font(.callout).foregroundStyle(.secondary)
                }
            } else if !editor.notice.isEmpty {
                Text(editor.notice).font(.caption).foregroundStyle(.secondary)
            }
            Text("选择后保存到当前布局，点击「应用到小屏」生效。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width:560)
        .buttonStyle(DeskIsleButtonStyle())
        .interactiveDismissDisabled(editor.importingModel)
    }
}
