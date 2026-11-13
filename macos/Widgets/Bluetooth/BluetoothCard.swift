import SwiftUI

struct BluetoothCard: View {
    let content: BluetoothCardContent
    let footprint: GridSize
    let screenSize: CGSize
    let origin: CGPoint
    let material: FrostedCardMaterial

    private var size: CGSize { CGSize(width: footprint.width, height: footprint.height) }
    private var muted: Color { material.muted }
    private var compact: Bool { footprint == .bluetooth }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Label("蓝牙设备", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 4)
                if case .connected(let devices) = content.accessories, !devices.isEmpty {
                    Text("\(devices.count) 已连接")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(muted)
                        .fixedSize()
                }
            }
            .frame(height: 24)
            VStack(alignment: .leading, spacing: 0) {
                row("本机", symbol: "laptopcomputer", level: content.computerBattery)
                rowSeparator
                switch content.accessories {
                case .loading:
                    empty("正在读取设备", symbol: "arrow.triangle.2.circlepath")
                case .off:
                    empty("蓝牙已关闭", symbol: "antenna.radiowaves.left.and.right.slash")
                case .unavailable:
                    empty("设备信息暂不可用", symbol: "exclamationmark.circle")
                case .connected(let devices):
                    if devices.isEmpty {
                        empty("未连接蓝牙设备", symbol: "dot.radiowaves.left.and.right")
                    } else {
                        ForEach(0..<min(2, devices.count), id: \.self) { index in
                            if index > 0 { rowSeparator }
                            let device = devices[index]
                            row(device.name, symbol: device.symbol, level: device.level, details: device.batteryDetails)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .foregroundStyle(material.ink)
        .background {
            FrostedCardBackground(size: size, screenSize: screenSize, origin: origin, material: material)
        }
    }

    private var rowSeparator: some View {
        Rectangle().fill(muted.opacity(0.18)).frame(height: 1).padding(.leading, 27)
    }

    private func row(_ name: String, symbol: String, level: Int?, details: String = "") -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(muted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: compact ? 2 : 3) {
                HStack(spacing: 4) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(compact || !details.isEmpty ? 1 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let level {
                        HStack(spacing: 4) {
                            Text("\(level)%").font(.system(size: 12, weight: .semibold).monospacedDigit())
                            Image(systemName: batterySymbol(level))
                                .font(.system(size: 13))
                        }
                        .fixedSize()
                    } else {
                        Text("—").font(.system(size: 12))
                    }
                }
                if !details.isEmpty {
                    Text(details)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(muted)
                        .lineLimit(1)
                }
            }
        }
        .frame(height: compact ? 34 : 46)
    }

    private func empty(_ title: String, symbol: String) -> some View {
        VStack(spacing: compact ? 4 : 8) {
            Image(systemName: symbol).font(.system(size: compact ? 18 : 23))
            Text(title).font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(muted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case 0: "battery.0percent"
        case 1...25: "battery.25percent"
        case 26...50: "battery.50percent"
        case 51...75: "battery.75percent"
        default: "battery.100percent"
        }
    }
}
