import AppKit
import Foundation

extension WidgetRuntime {
    func refreshBluetoothIfNeeded() {
        guard draft.bluetooth != nil || (connected && applied.bluetooth != nil), !bluetoothFetching,
              ProcessInfo.processInfo.systemUptime >= nextBluetoothRead else { return }
        bluetoothFetching = true
        Task {
            let content = await BluetoothSource.fetch()
            if bluetoothContent != content { bluetoothContent = content }
            nextBluetoothRead = ProcessInfo.processInfo.systemUptime + Double(connections.localPlugins.bluetoothInterval)
            bluetoothFetching = false
        }
    }

    func displayBluetooth(in layout: ScreenLayout) async {
        await sendWidget(WidgetData.Bluetooth(bluetoothContent), to: layout.bluetooth, notice: \.bluetoothDisplayNotice)
    }

}
