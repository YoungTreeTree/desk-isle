import AppKit
import Foundation

extension WidgetRuntime {
    func refreshCodexIfNeeded(force: Bool = false) {
        guard usesCodex || force else {
            nextCodexRead = .distantPast
            return
        }
        guard connections.profile.codex.enabled else {
            if codexData != nil { codexData = nil }
            if connections.codexStatus != .disabled { connections.codexStatus = .disabled }
            return
        }
        guard !codexFetching, force || Date() >= nextCodexRead else { return }
        let configuration = connections.profile.codex
        codexFetching = true
        connections.codexStatus = .checking
        Task {
            let result = await CodexCardData.fetch(configuration: configuration, previous: codexData)
            codexFetching = false
            guard configuration == connections.profile.codex else { return }
            connections.codexStatus = result.status
            if result.data != codexData { codexData = result.data }
            let now = Date()
            let midnight = Calendar.current.dateInterval(of: .day, for: now)?.end ?? .distantFuture
            nextCodexRead = min(midnight, now.addingTimeInterval(180))
        }
    }

    func displayCodex(in layout: ScreenLayout) async {
        await sendWidget(WidgetData.Codex(codexData), to: layout.codex, notice: \.codexDisplayNotice)
    }

}
