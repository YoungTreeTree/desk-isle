import AppKit
import Foundation

extension WidgetRuntime {
    func refreshGarminIfNeeded(force: Bool = false) {
        guard draft.garmin != nil || (connected && applied.garmin != nil) || force else { return }
        guard connections.profile.garmin.enabled else {
            let empty = GarminCardContent(error: .disabled)
            if garminContent != empty { garminContent = empty }
            if connections.garminStatus != .disabled { connections.garminStatus = .disabled }
            return
        }
        guard !garminFetching, force || ProcessInfo.processInfo.systemUptime >= nextGarminRead else { return }
        let configuration = connections.profile.garmin
        garminFetching = true
        connections.garminStatus = .checking
        Task {
            let result = await GarminSource.fetch(configuration: configuration)
            garminFetching = false
            guard configuration == connections.profile.garmin else { return }
            switch result {
            case .success(let snapshot):
                garminContent = GarminCardContent(snapshot: snapshot)
                connections.garminStatus = .init(kind: .ready, title: "已连接", detail: "已读取佳明中国区账号的健康摘要。")
            case .failure(let error):
                garminContent.error = error
                connections.garminStatus = .init(kind: error == .login || error == .setup || error == .region ? .setup : .unavailable,
                                                title: error.rawValue, detail: "可在插件配置中检查连接或重新登录。暂时失败会保留上次数据。")
            }
            nextGarminRead = ProcessInfo.processInfo.systemUptime + 10 * 60
        }
    }

    func displayGarmin(in layout: ScreenLayout) async {
        await sendWidget(WidgetData.Garmin(garminContent), to: layout.garmin, notice: \.garminDisplayNotice)
    }

}
