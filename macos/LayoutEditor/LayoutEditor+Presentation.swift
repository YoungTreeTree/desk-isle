import Foundation

// Read-only presentation facade; mutations stay with their owning runtime.
extension LayoutEditor {
    var garminContent: GarminCardContent { widgets.garminContent }
    var codexData: CodexCardData? { widgets.codexData }
    var bluetoothContent: BluetoothCardContent { widgets.bluetoothContent }
    var macLoad: MacLoadSnapshot { widgets.macLoad }
    var notificationMotion: NotificationMotion { widgets.notificationMotion }
    var notificationSnapshot: NotificationSnapshot { widgets.notificationSnapshot }
    var codexSessionURL: URL? { widgets.codexSessionURL }
    var garminDisplayNotice: String? { widgets.garminDisplayNotice }
    var codexDisplayNotice: String? { widgets.codexDisplayNotice }
    var bluetoothDisplayNotice: String? { widgets.bluetoothDisplayNotice }
    var macLoadDisplayNotice: String? { widgets.macLoadDisplayNotice }
    var notificationListenError: String? { widgets.notificationListenError }
    var notificationDisplayNotice: String? { widgets.notificationDisplayNotice }
    var pictures: [Int: PictureAsset] { pictureRuntime.pictures }
    var pictureDisplayNotices: [Int: String] { pictureRuntime.pictureDisplayNotices }
    func startNotifications() { widgets.startNotifications() }
    func stopNotifications() { widgets.stopNotifications() }
    func stopPicturePlayback() { pictureRuntime.stopPicturePlayback() }
    func testNotification() { widgets.testNotification() }
    func checkCodexConnection() { widgets.checkCodexConnection() }
    func checkGarminConnection() { widgets.checkGarminConnection() }
}
