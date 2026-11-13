import SwiftUI


struct DeskIsleWindow: View {
    private enum Page: CaseIterable {
        case layout, display, connections

        var title: String {
            switch self {
            case .layout: "桌面布局"
            case .display: "显示设置"
            case .connections: "插件配置"
            }
        }

        var icon: String {
            switch self {
            case .layout: "rectangle.on.rectangle"
            case .display: "display"
            case .connections: "puzzlepiece.extension"
            }
        }
    }

    let editor: LayoutEditor
    let displaySettings: DisplaySettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var page: Page

    init(editor: LayoutEditor, displaySettings: DisplaySettings) {
        self.editor = editor
        self.displaySettings = displaySettings
        _page = State(initialValue: editor.connections.profile.setupComplete ? .layout : .connections)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                tabs
                Spacer()
                ScreenConnectionStatus(editor: editor)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()

            switch page {
            case .layout:
                LayoutPage(editor: editor, showConnections: { page = .connections })
            case .display:
                DisplaySettingsView(settings: displaySettings)
            case .connections:
                ConnectionSettingsView(editor: editor, settings: editor.connections,
                                       showLayout: { page = .layout })
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 3) {
            ForEach(Page.allCases, id: \.self) { tab($0) }
        }
        .padding(3)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("桌屿页面")
    }

    private func tab(_ target: Page) -> some View {
        let selected = page == target
        return Button { page = target } label: {
            HStack(spacing: 7) {
                Image(systemName: target.icon)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(target.title)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .font(.system(size: 13, weight: selected ? .semibold : .medium))
            .padding(.horizontal, 12)
            .frame(height: 29)
            .background {
                let shape = RoundedRectangle(cornerRadius: 7)
                if selected {
                    shape.fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.white)
                        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(DeskIsleRowButtonStyle(cornerRadius: 7))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ScreenConnectionStatus: View {
    @ObservedObject var editor: LayoutEditor

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(editor.connected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(editor.connected ? "小屏已连接" : "等待小屏连接")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
}
