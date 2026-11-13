import SwiftUI

struct MacLoadCard: View {
    let sample: MacLoadSnapshot
    let footprint: GridSize
    let screenSize: CGSize
    let origin: CGPoint
    let material: FrostedCardMaterial

    private var large: Bool { footprint == .macLoadLarge }
    private var pressureColor: Color {
        switch sample.memoryPressure {
        case .normal: material.accent
        case .warning, .critical: material.chartAmber
        case .unknown: material.muted
        }
    }

    var body: some View {
        let size = CGSize(width: footprint.width, height: footprint.height)
        Canvas { context, _ in
            let inset: CGFloat = 16, width = size.width - 32
            func label(_ value: String, _ x: CGFloat, _ y: CGFloat, _ fontSize: CGFloat,
                       _ color: Color, weight: Font.Weight = .regular, right: Bool = false) {
                context.draw(Text(value).font(.system(size: fontSize, weight: weight).monospacedDigit())
                    .foregroundStyle(color), at: CGPoint(x: x, y: y), anchor: right ? .topTrailing : .topLeading)
            }
            func rect(_ box: CGRect, _ color: Color, radius: CGFloat = 0) {
                context.fill(Path(roundedRect: box, cornerRadius: radius), with: .color(color))
            }
            // A quiet header, then four aligned readings with units on the baseline.
            context.stroke(Path(roundedRect: CGRect(x: 16, y: 16, width: 16, height: 12), cornerRadius: 3),
                           with: .color(material.accent), lineWidth: 1.5)
            rect(CGRect(x: 22, y: 29, width: 4, height: 2), material.accent, radius: 1)
            label("Mac 负载", 40, 12, 18, material.ink, weight: .semibold)
            label(sample.memoryPressure.label, size.width - inset, 16, 12, pressureColor, right: true)

            let column = width / 4
            let labelY: CGFloat = large ? 52 : 45
            let numberY: CGFloat = large ? 72 : 64
            let numberSize: CGFloat = large ? 30 : 25
            let metrics: [(String, String, String, Color)] = [
                ("CPU", sample.cpu.map(String.init) ?? "—", "%", material.accent),
                ("GPU", sample.gpu.map(String.init) ?? "—", "%", material.chartAmber),
                ("CPU 最高温", sample.cpuTemperature.map(String.init) ?? "—", "°C", material.muted),
                ("整机功耗", power, "W", material.muted),
            ]
            for (index, metric) in metrics.enumerated() {
                let x = inset + CGFloat(index) * column
                label(metric.0, x, labelY, large ? 13 : 12, metric.3)
                let value = Text(metric.1).font(.system(size: numberSize, weight: .medium).monospacedDigit())
                    .foregroundStyle(material.ink)
                let resolved = context.resolve(value)
                context.draw(resolved, at: CGPoint(x: x, y: numberY), anchor: .topLeading)
                if metric.1 != "—" {
                    label(metric.2, x + resolved.measure(in: size).width + 2, numberY + numberSize - 13, 12, material.muted)
                }
                if index != 3 {
                    rect(CGRect(x: x + column - 8, y: labelY + 3, width: 1, height: large ? 44 : 37),
                         material.ink.opacity(0.10))
                }
            }

            let memoryY: CGFloat = large ? 118 : 103
            label("内存", inset, memoryY, 13, material.muted)
            label(memory, size.width - inset, memoryY - (large ? 1 : 0), large ? 15 : 13, material.ink, right: true)
            let barY: CGFloat = large ? 142 : 124
            rect(CGRect(x: inset, y: barY, width: width, height: 4), material.ink.opacity(0.12), radius: 2)
            if let used = sample.memoryUsedMiB, let total = sample.memoryTotalMiB, total > 0 {
                rect(CGRect(x: inset, y: barY, width: width * min(1, max(0, Double(used) / Double(total))), height: 4),
                     pressureColor, radius: 2)
            }
            if large {
                label("最近 1 分钟", inset, 155, 11, material.muted)
                label("CPU", size.width - 62, 155, 11, material.accent, right: true)
                label("GPU", size.width - inset, 155, 11, material.chartAmber, right: true)
                drawHistory(context, in: CGRect(x: inset, y: 174, width: width, height: 30))
            }
            let footerY = size.height - 23
            label("Miucs \(percent(sample.miucsTenths))", inset, footerY, 11, material.muted)
            label("桌屿 \(percent(sample.deskIsleTenths))", size.width - inset, footerY, 11, material.muted, right: true)
        }
        .frame(width: size.width, height: size.height)
        .background { FrostedCardBackground(size: size, screenSize: screenSize, origin: origin, material: material) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mac 负载")
        .accessibilityValue("CPU \(sample.cpu.map { "\($0)%" } ?? "—")，GPU \(sample.gpu.map { "\($0)%" } ?? "—")，CPU 最高温 \(sample.cpuTemperature.map { "\($0)°C" } ?? "—")，整机功耗 \(power) W，内存 \(memory)，\(sample.memoryPressure.label)")
    }

    private var power: String {
        guard let value = sample.systemPowerTenths else { return "—" }
        return value >= 1000 ? String((value + 5) / 10) : String(format: "%.1f", Double(value) / 10)
    }

    private var memory: String {
        let used = sample.memoryUsedMiB.map { String(format: "%.1f", Double($0) / 1024) } ?? "—"
        let total = sample.memoryTotalMiB.map { String(format: "%g", Double($0) / 1024) } ?? "—"
        return "已用 \(used) / \(total) GB"
    }

    private func percent(_ tenths: Int?) -> String {
        guard let tenths else { return "—" }
        return String(format: "%.1f%%", Double(tenths) / 10)
    }

    private func drawHistory(_ context: GraphicsContext, in box: CGRect) {
        var grid = Path()
        for y in [box.minY, box.midY, box.maxY] {
            grid.move(to: CGPoint(x: box.minX, y: y))
            grid.addLine(to: CGPoint(x: box.maxX, y: y))
        }
        context.stroke(grid, with: .color(material.ink.opacity(0.10)), lineWidth: 1)
        func draw(_ values: [Int?], color: Color) {
            let step = (box.width - 1) / CGFloat(max(1, values.count - 1))
            var series = Path()
            var previous = false
            for (index, value) in values.enumerated() {
                guard let value, (0...100).contains(value) else { previous = false; continue }
                let x = box.minX + (values.count == 1 ? box.width - 1 : CGFloat(index) * step)
                let point = CGPoint(x: x, y: box.minY + (box.height - 1) * CGFloat(100 - value) / 100)
                if previous { series.addLine(to: point) }
                else { series.move(to: point); series.addLine(to: CGPoint(x: x + 1, y: point.y)) }
                previous = true
            }
            context.stroke(series, with: .color(color), lineWidth: 2)
        }
        draw(sample.gpuHistory, color: material.chartAmber)
        draw(sample.cpuHistory, color: material.accent)
    }
}
