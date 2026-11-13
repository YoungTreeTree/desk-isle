import AppKit
import Foundation

extension WidgetRuntime {
    func refreshMacLoadIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard draft.macLoad != nil || (connected && applied.macLoad != nil),
              !macLoadFetching, now >= nextMacLoadRead else { return }
        macLoadFetching = true
        nextMacLoadRead = now + Double(connections.localPlugins.macInterval)
        let miucs = NSRunningApplication.runningApplications(withBundleIdentifier: "com.miucs.app").map(\.processIdentifier)
        Task {
            let sample = await macLoadSource.sample(miucs: miucs)
            macLoadFetching = false
            if sample != macLoad { macLoad = sample }
        }
    }

    func displayMacLoad(in layout: ScreenLayout) async {
        guard let component = layout.macLoad else { return }
        await sendWidget(WidgetData.MacLoad(macLoad, large: component.footprint == .macLoadLarge),
                         to: component, notice: \.macLoadDisplayNotice)
    }
}
