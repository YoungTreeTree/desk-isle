import SwiftUI

struct GarminCardContent: Equatable {
    var snapshot: GarminSnapshot?
    var error: GarminReadError?

    var statusText: String {
        guard let snapshot else { return "GARMIN CONNECT" }
        let time = snapshot.lastSyncAt ?? snapshot.fetchedAt
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = Date(timeIntervalSince1970: time)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDateInToday(date) ? "HH:mm" : "MM-dd HH:mm"
        let prefix = error == nil ? (snapshot.lastSyncAt == nil ? "更新" : "同步") : "上次同步"
        return "\(prefix) \(formatter.string(from: date))"
    }
}

struct GarminCard: View {
    let content: GarminCardContent
    let screenSize: CGSize
    let origin: CGPoint
    let material: FrostedCardMaterial

    private static let width = CGFloat(GridSize.garmin.width)
    private static let height = CGFloat(GridSize.garmin.height)
    private var ink: Color { material.ink }
    private var muted: Color { material.muted }
    private var accent: Color { material.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(accent)
                Text("佳明健康").fontWeight(.semibold)
                Spacer(minLength: 8)
                Text(content.statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(muted)
                    .lineLimit(1)
            }
            .font(.system(size: 20))

            if let snapshot = content.snapshot {
                steps(snapshot)
                metrics(snapshot)
                stressChart(snapshot.stress)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(accent)
                    Text(content.error?.rawValue ?? "正在读取健康数据")
                        .font(.system(size: 21, weight: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .foregroundStyle(ink)
        .background {
            FrostedCardBackground(size: CGSize(width: Self.width, height: Self.height),
                                  screenSize: screenSize, origin: origin, material: material)
        }
    }

    private func steps(_ snapshot: GarminSnapshot) -> some View {
        let goal = snapshot.stepGoal.flatMap { $0 > 0 ? $0 : nil }
        let progress = goal.map { min(1, Double(snapshot.steps ?? 0) / Double($0)) } ?? 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(snapshot.steps.map { $0.formatted(.number.locale(Locale(identifier: "zh_CN"))) } ?? "—")
                    .font(.system(size: 43, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("步").font(.system(size: 16)).foregroundStyle(muted)
                Spacer()
                if let goal {
                    Text("目标 \(goal.formatted(.number.locale(Locale(identifier: "zh_CN"))))")
                        .font(.system(size: 15))
                        .foregroundStyle(muted)
                }
            }
            .monospacedDigit()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.opacity(0.15))
                    Capsule().fill(accent).frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: 5)
        }
    }

    private func metrics(_ snapshot: GarminSnapshot) -> some View {
        let sleep = snapshot.sleepSeconds.map { String(format: "%d:%02d", $0 / 3600, $0 % 3600 / 60) } ?? "—"
        return HStack(spacing: 7) {
            metric("睡眠", value: sleep, detail: snapshot.sleepScore.map { "评分 \($0)" } ?? "时:分")
            metric("身体电量", value: value(snapshot.bodyBattery), detail: "/ 100")
            metric("静息心率", value: value(snapshot.restingHeartRate), detail: "bpm")
            metric("夜间 HRV", value: value(snapshot.hrv), detail: "ms")
        }
    }

    private func value(_ metric: Int?) -> String {
        metric.map(String.init) ?? "—"
    }

    private func metric(_ name: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.system(size: 13)).foregroundStyle(muted)
            Text(value).font(.system(size: 23, weight: .semibold)).monospacedDigit()
            Text(detail).font(.system(size: 12)).foregroundStyle(muted)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(material.tileOpacity), in: RoundedRectangle(cornerRadius: 9))
    }

    private func stressChart(_ points: [Int?]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("近 24 小时压力")
                .font(.system(size: 15, weight: .medium))
            if points.contains(where: { $0 != nil }) {
                Canvas { context, size in
                    let step = size.width / CGFloat(points.count)
                    for (index, point) in points.enumerated() {
                        guard let point else { continue }
                        let height = max(2, size.height * CGFloat(min(100, max(0, point))) / 100)
                        let rect = CGRect(x: CGFloat(index) * step, y: size.height - height,
                                          width: max(1, step - 1), height: height)
                        let color = point < 26 ? accent : material.chartAmber
                        context.fill(Path(rect), with: .color(color))
                    }
                }
                .frame(height: 42)
                HStack {
                    Text("24 小时前")
                    Spacer()
                    Text("采集时")
                }
                .font(.system(size: 11))
                .foregroundStyle(muted)
            } else {
                Text("暂无压力记录")
                    .font(.system(size: 14))
                    .foregroundStyle(muted)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .center)
            }
        }
    }
}
