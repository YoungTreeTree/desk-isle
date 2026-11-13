import XCTest
@testable import DeskIsle

final class ConnectionTests: XCTestCase {
    @MainActor
    func testFreshInstallStaysOptInAcrossRestartAndGuideCompletion() throws {
        let name = "deskisle.tests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        let settings = ConnectionSettings(preferences: preferences, inspectConnections: false)
        XCTAssertFalse(settings.profile.setupComplete)
        XCTAssertFalse(settings.profile.codex.enabled)
        XCTAssertFalse(settings.profile.garmin.enabled)
        let pet = PetSettings(usb: LayoutUSB(), preferences: preferences, importLegacySettings: false)
        XCTAssertFalse(pet.audioEnabled)
        XCTAssertFalse(pet.keyboardEnabled)
        let restarted = ConnectionSettings(preferences: preferences, inspectConnections: false)
        XCTAssertFalse(restarted.profile.setupComplete, "Pet defaults must not turn a fresh user into a legacy installation")
        restarted.completeSetup()
        let complete = ConnectionSettings(preferences: preferences, inspectConnections: false)
        XCTAssertTrue(complete.profile.setupComplete)
        XCTAssertFalse(complete.profile.codex.enabled)
        XCTAssertFalse(complete.profile.garmin.enabled)
    }

    @MainActor
    func testExistingSettingsMigrateOnceAndKeepExplicitChoices() {
        let name = "deskisle.tests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        preferences.set("yuru-camp", forKey: "pet.skin")
        preferences.set(true, forKey: "pet.keyboardPermissionRequested")
        preferences.set(false, forKey: "pet.audio")
        let settings = ConnectionSettings(preferences: preferences, inspectConnections: false)
        XCTAssertTrue(settings.profile.setupComplete)
        XCTAssertTrue(settings.profile.codex.enabled)
        XCTAssertTrue(settings.profile.garmin.enabled)
        XCTAssertTrue(settings.profile.garmin.sessionDirectory?.hasSuffix("/.garminconnect") == true)
        let pet = PetSettings(usb: LayoutUSB(), preferences: preferences, importLegacySettings: true)
        XCTAssertEqual(pet.selectedID, "yuru-camp")
        XCTAssertTrue(pet.keyboardEnabled)
        XCTAssertFalse(pet.audioEnabled)
        settings.updateCodex { $0.enabled = false; $0.home = "/tmp/another-codex" }
        let restored = ConnectionSettings(preferences: preferences, inspectConnections: false)
        XCTAssertFalse(restored.profile.codex.enabled)
        XCTAssertEqual(restored.profile.codex.home, "/tmp/another-codex")
    }

    @MainActor
    func testCorruptProfileIsPreservedAndDoesNotEnableAccounts() {
        let name = "deskisle.tests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        let invalid = Data("invalid".utf8)
        preferences.set(invalid, forKey: ConnectionSettings.key)
        preferences.set("yuru-camp", forKey: "pet.skin")
        let settings = ConnectionSettings(preferences: preferences, inspectConnections: false)
        XCTAssertNotNil(settings.persistenceError)
        XCTAssertFalse(settings.profile.codex.enabled)
        XCTAssertFalse(settings.profile.garmin.enabled)
        XCTAssertEqual(preferences.data(forKey: ConnectionSettings.key), invalid)
    }

    func testCodexPathsShareOneHomeAndRespectExplicitSelection() throws {
        let home = URL(fileURLWithPath: "/tmp/user")
        var connection = CodexConnection()
        XCTAssertEqual(connection.homeURL(environment: [:], userHome: home).path, "/tmp/user/.codex")
        XCTAssertEqual(connection.homeURL(environment: ["CODEX_HOME": "/tmp/environment"], userHome: home).path, "/tmp/environment")
        connection.home = "/tmp/selected"
        XCTAssertEqual(connection.homeURL(environment: ["CODEX_HOME": "/tmp/environment"], userHome: home).path, "/tmp/selected")
        connection.executable = "/nonexistent/deskisle-test-codex"
        XCTAssertNil(connection.executableURL(environment: ["CODEX_BINARY_PATH": "/bin/sh"]))
        connection.executable = "/bin/sh"
        XCTAssertEqual(connection.executableURL()?.path, "/bin/sh")
        connection.executable = "/tmp"
        XCTAssertNil(connection.executableURL(), "An executable directory is not an executable program")
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        connection.executable = link.path
        XCTAssertEqual(connection.executableURL(), link, "Package managers commonly install CLI symlinks")
    }

    func testGarminChinaProfileMigrationAndUnsupportedRegion() throws {
        let decoder = JSONDecoder()
        let china = try decoder.decode(GarminConnection.self, from: Data(
            #"{"enabled":true,"region":"china","sessionDirectory":"/tmp/china-account"}"#.utf8))
        XCTAssertTrue(china.enabled)
        XCTAssertEqual(china.sessionDirectory, "/tmp/china-account")
        let global = try decoder.decode(GarminConnection.self, from: Data(
            #"{"enabled":true,"region":"global","sessionDirectory":"/tmp/global-account"}"#.utf8))
        XCTAssertFalse(global.enabled)
        XCTAssertNil(global.sessionDirectory)
        let encoded = try JSONEncoder().encode(china)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["region"])
        XCTAssertEqual(try decoder.decode(GarminConnection.self, from: encoded), china)
    }

    func testDisabledAndUnconfiguredSourcesDoNotReadAccounts() async {
        let codex = await CodexCardData.fetch(configuration: CodexConnection(), previous: nil)
        XCTAssertNil(codex.data)
        XCTAssertEqual(codex.status, .disabled)
        let garmin = await GarminSource.fetch(configuration: GarminConnection())
        guard case .failure(.disabled) = garmin else { return XCTFail("Disabled source performed a read") }
        var missing = GarminConnection()
        missing.enabled = true
        missing.sessionDirectory = "/nonexistent/deskisle-test-garmin"
        guard case .failure(.setup) = await GarminSource.fetch(configuration: missing) else {
            return XCTFail("Missing session must be reported before starting a helper")
        }
    }

    func testHookInspectionDistinguishesMissingPartialAndInstalled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("a user's helper")
        let legacy = root.appendingPathComponent("old-helper")
        XCTAssertEqual(CodexHookConnection.inspect(home: root, helper: helper, legacyHelper: legacy).kind, .setup)
        let file = root.appendingPathComponent("hooks.json")
        try Data("{}".utf8).write(to: file)
        XCTAssertEqual(CodexHookConnection.inspect(home: root, helper: helper, legacyHelper: legacy).kind, .setup)
        let command = CodexHookConnection.command(for: helper)
        XCTAssertTrue(command.contains("'\"'\"'"))
        let hooks = Dictionary(uniqueKeysWithValues: CodexHookConnection.events.map {
            ($0, [["hooks": [["type": "command", "command": command]]]])
        })
        try JSONSerialization.data(withJSONObject: ["hooks": hooks]).write(to: file)
        XCTAssertEqual(CodexHookConnection.inspect(home: root, helper: helper, legacyHelper: legacy).kind, .setup)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        XCTAssertEqual(CodexHookConnection.inspect(home: root, helper: helper, legacyHelper: legacy).kind, .ready)
        try Data("broken".utf8).write(to: file)
        XCTAssertEqual(CodexHookConnection.inspect(home: root, helper: helper, legacyHelper: legacy).kind, .unavailable)
    }
}
