import Foundation

enum WidgetData {
    private static func bounded(_ text: String, bytes: Int) -> String {
        String(decoding: text.utf8.prefix(bytes), as: UTF8.self)
    }

    struct Codex: WidgetGlyphSource {
        struct Quota: Encodable, Sendable {
            let remaining: Int?
            let reset: String?

            init(_ quota: CodexQuota) {
                remaining = quota.remainingPercent
                reset = quota.resetLabel
            }
        }

        let plan: String?
        let tokens: String?
        let localTokens: Bool
        let staleQuotas: Bool
        let week: Quota?
        let fiveHours: Quota?

        var glyphRuns: [WidgetGlyphRun] {
            [WidgetGlyphRun(plan, 13), WidgetGlyphRun(week?.reset, 12), WidgetGlyphRun(fiveHours?.reset, 12)]
        }

        init(_ usage: CodexCardData?) {
            plan = usage?.plan.map { WidgetData.bounded($0.uppercased(), bytes: 48) }
            tokens = usage?.tokens.map(String.init)
            localTokens = usage?.localTokens == true
            staleQuotas = usage?.staleQuotas == true
            week = usage?.week.map(Quota.init)
            fiveHours = usage?.fiveHours.map(Quota.init)
        }
    }

    struct Garmin: WidgetGlyphSource {
        let snapshot: GarminSnapshot?
        let status: String
        let error: String?

        var glyphRuns: [WidgetGlyphRun] { [WidgetGlyphRun(status, 13), WidgetGlyphRun(error, 21)] }

        init(_ content: GarminCardContent) {
            snapshot = content.snapshot
            status = content.statusText
            error = content.error?.rawValue
        }
    }

    struct Bluetooth: WidgetGlyphSource {
        struct Device: Encodable, Sendable {
            let name: String
            let symbol: String
            let level: Int?
            let left: Int?
            let right: Int?
            let box: Int?

            init(_ device: BluetoothDevice) {
                name = WidgetData.bounded(device.name, bytes: 128)
                symbol = device.symbol
                level = device.level
                left = device.leftBattery
                right = device.rightBattery
                box = device.caseBattery
            }
        }

        let computerBattery: Int?
        let status: String
        let count: Int
        let devices: [Device]

        var glyphRuns: [WidgetGlyphRun] { devices.map { WidgetGlyphRun($0.name, 14) } }

        init(_ content: BluetoothCardContent) {
            computerBattery = content.computerBattery
            switch content.accessories {
            case .connected(let connected):
                status = "connected"
                count = connected.count
                devices = connected.prefix(2).map(Device.init)
            case .loading, .off, .unavailable:
                status = switch content.accessories {
                case .off: "off"
                case .unavailable: "unavailable"
                default: "loading"
                }
                count = 0
                devices = []
            }
        }
    }

    struct MacLoad: WidgetGlyphSource {
        let cpu: Int?
        let gpu: Int?
        let cpuTemperature: Int?
        let systemPowerTenths: Int?
        let memoryUsedMiB: Int?
        let memoryTotalMiB: Int?
        let memoryPressure: String
        let miucsTenths: Int?
        let deskIsleTenths: Int?
        let cpuHistory: [Int?]?
        let gpuHistory: [Int?]?

        var glyphRuns: [WidgetGlyphRun] { [] }

        init(_ sample: MacLoadSnapshot, large: Bool) {
            cpu = sample.cpu
            gpu = sample.gpu
            cpuTemperature = sample.cpuTemperature
            systemPowerTenths = sample.systemPowerTenths
            memoryUsedMiB = sample.memoryUsedMiB
            memoryTotalMiB = sample.memoryTotalMiB
            memoryPressure = sample.memoryPressure.rawValue
            miucsTenths = sample.miucsTenths
            deskIsleTenths = sample.deskIsleTenths
            cpuHistory = large ? Array(sample.cpuHistory.suffix(32)) : nil
            gpuHistory = large ? Array(sample.gpuHistory.suffix(32)) : nil
        }
    }

    struct Notice: WidgetGlyphSource {
        struct Item: Encodable, Sendable {
            let style: String
            let source: String
            let project: String?
            let title: String
            let body: String?
            let elapsedSeconds: Int?

            init(_ item: NotificationSnapshot.Item, includeBody: Bool = true) {
                style = item.style.rawValue
                source = NotificationEvent.sourceName(item.source)
                project = item.project.map { WidgetData.bounded($0, bytes: 96) }
                title = WidgetData.bounded(item.title, bytes: 128)
                body = includeBody ? WidgetData.bounded(item.body, bytes: 768) : nil
                elapsedSeconds = item.elapsedSeconds
            }
        }

        let item: Item?
        let running: Int
        let waiting: Int
        let others: [Item]

        var glyphRuns: [WidgetGlyphRun] {
            var runs = others.flatMap {
                [WidgetGlyphRun($0.title, 15), WidgetGlyphRun($0.project ?? $0.source, 13)]
            }
            if let item {
                runs += [WidgetGlyphRun(item.source, 15, 24), WidgetGlyphRun(item.project, 15, 24),
                         WidgetGlyphRun(item.title, 17, 24), WidgetGlyphRun(item.body, 17)]
            }
            return runs
        }

        init(_ snapshot: NotificationSnapshot) {
            item = snapshot.item.map { Item($0) }
            running = snapshot.running
            waiting = snapshot.waiting
            others = snapshot.otherSessions.map { Item($0, includeBody: false) }
        }
    }
}
