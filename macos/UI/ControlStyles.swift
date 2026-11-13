import SwiftUI

/// Shared feedback for settings actions. State lives on each button, so hovering
/// never invalidates the whole settings page or starts a repeating animation.
struct DeskIsleButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration, prominent: prominent)
    }

    private struct Feedback: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isFocused) private var isFocused
        @State private var hovered = false

        private var active: Bool { isEnabled && (hovered || isFocused) }
        private var pressed: Bool { isEnabled && configuration.isPressed }
        private var tint: Color { configuration.role == .destructive ? .red : .accentColor }
        private var fill: Color {
            if prominent { return tint }
            return active || pressed ? tint.opacity(pressed ? 0.20 : 0.10) : Color.primary.opacity(0.055)
        }

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(prominent ? Color.white : configuration.role == .destructive ? tint : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(fill, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(prominent ? (pressed ? Color.black.opacity(0.16) : active ? Color.white.opacity(0.13) : .clear) : .clear)
                        .allowsHitTesting(false)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(active || pressed ? tint.opacity(0.55) : Color.primary.opacity(0.10))
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(active && !pressed ? 0.10 : 0), radius: 2, y: 1)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .onHover { hovered = $0 }
                .onDisappear { hovered = false }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: active)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
        }
    }
}

/// Adds interaction feedback without replacing a row's selected appearance.
struct DeskIsleRowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 9

    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct Feedback: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isFocused) private var isFocused
        @State private var hovered = false

        private var active: Bool { isEnabled && (hovered || isFocused) }
        private var pressed: Bool { isEnabled && configuration.isPressed }

        var body: some View {
            configuration.label
                .background(Color.accentColor.opacity(pressed ? 0.16 : active ? 0.08 : 0),
                            in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.accentColor.opacity(pressed ? 0.45 : active ? 0.28 : 0))
                        .allowsHitTesting(false)
                }
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .onHover { hovered = $0 }
                .onDisappear { hovered = false }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: active)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
        }
    }
}

struct DeskIsleDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(DeskIsleRowButtonStyle(cornerRadius: 7))
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")
            if configuration.isExpanded {
                configuration.content.padding(.leading, 20)
            }
        }
    }
}
