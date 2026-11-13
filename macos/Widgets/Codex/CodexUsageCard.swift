import SwiftUI

struct CodexUsageCard: View {
    let usage: CodexCardData?
    let footprint: GridSize
    let screenSize: CGSize
    let origin: CGPoint
    let material: FrostedCardMaterial

    private var ink: Color { material.ink }
    private var muted: Color { material.muted }
    private var accent: Color { material.accent }
    private var tall: Bool { footprint.rows > GridSize.codex.rows }

    var body: some View {
        let size = CGSize(width: footprint.width, height: footprint.height)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 34, height: 34)
                    .background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                Text("Codex").font(.system(size: 25, weight: .bold))
                Spacer()
                if let plan = usage?.plan {
                    Text(plan.uppercased())
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.white.opacity(material.badgeOpacity), in: Capsule())
                }
            }
            HStack {
                Text("今日 Token")
                Spacer()
                if let usage, usage.tokens != nil { Text(usage.localTokens ? "本机统计" : "账号统计") }
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(muted)
            .padding(.top, tall ? 27 : 18)
            Text((usage?.tokens).map {
                $0.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US")))
            } ?? "—")
                .font(.system(size: tall || footprint == .codex ? 56 : 46, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            Rectangle().fill(ink.opacity(0.15)).frame(height: 1).padding(.vertical, tall ? 22 : 13)

            HStack {
                Text("订阅剩余额度")
                Spacer()
                if usage?.staleQuotas == true { Text("上次同步") }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(muted)
            .padding(.bottom, tall ? 13 : 7)
            quota("每周", usage?.week)
            quota("5 小时", usage?.fiveHours).padding(.top, tall ? 18 : 9)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: size.width, height: size.height)
        .foregroundStyle(ink)
        .background { FrostedCardBackground(size: size, screenSize: screenSize, origin: origin, material: material) }
        .environment(\.locale, Locale(identifier: "zh_CN"))
    }

    private func quota(_ label: String, _ window: CodexQuota?) -> some View {
        let remaining = window?.remainingPercent
        return VStack(spacing: tall ? 7 : 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.system(size: 15, weight: .semibold))
                if let reset = window?.resetLabel {
                    Text("\(reset) 重置")
                        .font(.system(size: 12))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(remaining.map { "\($0)%" } ?? "—")
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(remaining == nil ? muted : accent)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.opacity(0.15))
                    Capsule().fill(accent).frame(width: proxy.size.width * CGFloat(remaining ?? 0) / 100)
                }
            }
            .frame(height: 5)
        }
    }
}
