import SwiftUI

struct NotificationMotion {
    struct Frame {
        let snapshot: NotificationSnapshot
        let previous: NotificationSnapshot?
        let progress: Double
    }

    private static let transitionDuration = 0.36

    private(set) var snapshot = NotificationSnapshot.empty
    private var previous: NotificationSnapshot?
    private var transitionEnd: TimeInterval = 0

    var restingFrame: Frame { Frame(snapshot: snapshot, previous: nil, progress: 1) }

    mutating func update(to next: NotificationSnapshot, at time: TimeInterval) {
        if snapshot.isExpanded != next.isExpanded {
            previous = snapshot
            transitionEnd = time + Self.transitionDuration
        }
        snapshot = next
    }

    func frame(at time: TimeInterval) -> Frame {
        let remaining = transitionRemaining(at: time)
        guard remaining > 0 else { return restingFrame }
        let fraction = 1 - remaining / Self.transitionDuration
        let progress = fraction * fraction * (3 - 2 * fraction)
        return Frame(snapshot: snapshot, previous: previous, progress: progress)
    }

    func transitionRemaining(at time: TimeInterval) -> TimeInterval {
        min(Self.transitionDuration, max(0, transitionEnd - time))
    }
}

private extension NotificationSnapshot {
    var isRunning: Bool { item?.style == .running }
    var isExpanded: Bool { item != nil && !isRunning }
}

struct NotificationCardPreview: View {
    let motion: NotificationMotion
    let footprint: GridSize
    let screenSize: CGSize
    let origin: CGPoint
    let animates: Bool
    @Environment(\.deskWallpaper) private var wallpaper

    var body: some View {
        let size = CGSize(width: footprint.width, height: footprint.height)
        let remaining = motion.transitionRemaining(at: ProcessInfo.processInfo.systemUptime)
        ZStack(alignment: .top) {
            if let image = wallpaper?.image {
                ScreenWallpaper.portion(image, size: size, screenSize: screenSize, origin: origin)
            } else {
                Color(red: 0.14, green: 0.16, blue: 0.19)
            }
            if animates, remaining > 0 {
                let end = Date().addingTimeInterval(remaining)
                TimelineView(NotificationTransitionSchedule(end: end)) { tick in
                    let frame = tick.date >= end ? motion.restingFrame : motion.frame(at: ProcessInfo.processInfo.systemUptime)
                    NotificationCard(frame: frame, footprint: footprint, animatesWaveform: frame.previous == nil)
                }
            } else {
                NotificationCard(frame: motion.restingFrame, footprint: footprint, animatesWaveform: animates)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
    }
}

private struct NotificationTransitionSchedule: TimelineSchedule {
    let end: Date

    func entries(from start: Date, mode: Mode) -> some Sequence<Date> {
        let interval = mode == .lowFrequency ? 0.25 : 1.0 / 60
        return sequence(first: start) { $0 < end ? min($0.addingTimeInterval(interval), end) : nil }
    }
}

private struct NotificationWaveform: View {
    let accent: Color
    let animates: Bool

    var body: some View {
        Group {
            if animates {
                TimelineView(.animation(minimumInterval: 1.0 / 15)) { tick in
                    let phase = tick.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5
                    bars(at: phase)
                }
            } else {
                bars(at: 0)
            }
        }
        .frame(width: 25, height: 26)
    }

    private func bars(at phase: Double) -> some View {
        Canvas { context, size in
            var path = Path()
            for bar in 0..<5 {
                let angle = (phase - Double(bar) * 0.14) * 2 * Double.pi
                let height = CGFloat(7 + 17 * (0.5 + 0.5 * sin(angle)))
                let rect = CGRect(x: CGFloat(bar) * 5.5, y: (size.height - height) / 2, width: 3, height: height)
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: 1.5, height: 1.5))
            }
            context.fill(path, with: .color(accent))
        }
    }
}

private struct NotificationCard: View {
    let frame: NotificationMotion.Frame
    let footprint: GridSize
    let animatesWaveform: Bool

    private var size: CGSize { CGSize(width: footprint.width, height: footprint.height) }

    var body: some View {
        ZStack(alignment: .top) {
            if let previous = frame.previous {
                if previous.isExpanded {
                    island(previous, backdrop: 1 - frame.progress, showText: false)
                    island(frame.snapshot, backdrop: frame.progress, showText: true)
                } else {
                    island(frame.snapshot, backdrop: frame.progress, showText: false)
                    island(previous, backdrop: 1 - frame.progress, showText: true)
                }
            } else {
                island(frame.snapshot, backdrop: 1, showText: true)
            }
        }
        .padding(.top, 10)
    }

    @ViewBuilder
    private func island(_ snapshot: NotificationSnapshot, backdrop: Double, showText: Bool) -> some View {
        if let item = snapshot.item, snapshot.isExpanded {
            expanded(item, snapshot: snapshot, backdrop: backdrop, showText: showText)
        } else {
            compact(snapshot, backdrop: backdrop, showText: showText)
        }
    }

    private func compact(_ snapshot: NotificationSnapshot, backdrop: Double, showText: Bool) -> some View {
        let item = snapshot.item
        let accent = item?.style.accent ?? Color(red: 0.54, green: 0.72, blue: 0.83)
        let subtitle = item.map { item in
            if !item.body.isEmpty { return item.body }
            return item.project != nil && item.title != item.project ? item.title : ""
        } ?? ""
        let titleSize: CGFloat = snapshot.isRunning ? 24 : 28
        return HStack(spacing: 14) {
            if snapshot.isRunning {
                NotificationWaveform(accent: accent, animates: animatesWaveform)
            } else {
                Image(systemName: "bell.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.map { NotificationEvent.sourceName($0.source) + " · " + ($0.project ?? $0.title) } ?? "通知岛")
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.87))
                        .lineLimit(1)
                        .frame(maxWidth: 340, alignment: .leading)
                }
            }
            if !snapshot.counts.isEmpty {
                Text(snapshot.counts)
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 28)
        .frame(minWidth: 184, maxWidth: size.width - 24)
        .frame(height: 76)
        .fixedSize(horizontal: true, vertical: false)
        .opacity(showText ? 1 : 0)
        .background { glass(Capsule()).opacity(backdrop) }
    }

    private func expanded(_ item: NotificationSnapshot.Item, snapshot: NotificationSnapshot,
                          backdrop: Double, showText: Bool) -> some View {
        let wide = footprint == .notificationWide
        let showsSessions = wide && !snapshot.otherSessions.isEmpty
        let sideInset: CGFloat = wide ? 18 : 10
        return HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: wide ? 8 : 6) {
                header(item, counts: showsSessions ? "" : snapshot.counts)
                Text(item.title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(wide ? 2 : 1)
                if !item.body.isEmpty {
                    Text(item.body)
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.93))
                        .lineLimit(wide ? 4 : 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsSessions {
                otherSessions(snapshot.otherSessions)
            }
        }
        .padding(.horizontal, wide ? 26 : 16)
        .padding(.vertical, wide ? 20 : 11)
        .frame(width: size.width - 2 * sideInset, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .opacity(showText ? 1 : 0)
        .background {
            glass(RoundedRectangle(cornerRadius: wide ? 28 : 22, style: .continuous))
                .scaleEffect(0.64 + 0.36 * backdrop, anchor: .top)
                .opacity(backdrop)
        }
    }

    private func header(_ item: NotificationSnapshot.Item, counts: String) -> some View {
        let style = item.style
        let project = item.project == item.title ? nil : item.project
        let label = [NotificationEvent.sourceName(item.source), style.label, project]
            .compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 8) {
            Image(systemName: style.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(style.accent)
                .frame(width: 32, height: 32)
                .background(style.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(style.accent)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let seconds = item.elapsedSeconds {
                let duration = seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分 \(seconds % 60) 秒"
                Label("用时 " + duration, systemImage: "clock")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.84))
                    .fixedSize()
            } else if !counts.isEmpty {
                Text(counts)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.84))
                    .fixedSize()
            }
        }
    }

    private func otherSessions(_ sessions: [NotificationSnapshot.Item]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("其他会话")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
            ForEach(Array(sessions.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(item.style.accent)
                        .frame(width: 6, height: 6)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text((item.project ?? NotificationEvent.sourceName(item.source)) + " · " + item.style.label)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.83))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 220, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }

    private func glass(_ shape: some InsettableShape) -> some View {
        shape.fill(LinearGradient(colors: [Color(red: 0.06, green: 0.09, blue: 0.14).opacity(0.60),
                                          Color(red: 0.02, green: 0.03, blue: 0.06).opacity(0.68)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay { shape.strokeBorder(.white.opacity(0.24), lineWidth: 1) }
    }
}

extension NotificationSnapshot.Style {
    var label: String {
        switch self {
        case .running: "运行中"
        case .approval: "待审批"
        case .question: "待回复"
        case .info: "提醒"
        case .success: "已完成"
        case .warning: "提醒"
        case .error: "失败"
        case .interrupted: "已中断"
        }
    }

    var symbol: String {
        switch self {
        case .running: "waveform"
        case .approval: "lock.shield.fill"
        case .question: "bubble.left.fill"
        case .info: "bell.fill"
        case .success: "checkmark"
        case .warning: "exclamationmark"
        case .error: "xmark"
        case .interrupted: "pause.fill"
        }
    }

    var accent: Color {
        switch self {
        case .running, .info: Color(red: 0.60, green: 0.83, blue: 1)
        case .approval, .warning: Color(red: 1, green: 0.78, blue: 0.40)
        case .question: Color(red: 0.78, green: 0.74, blue: 1)
        case .success: Color(red: 0.57, green: 0.93, blue: 0.72)
        case .error: Color(red: 1, green: 0.61, blue: 0.63)
        case .interrupted: Color(red: 0.74, green: 0.78, blue: 0.83)
        }
    }
}
