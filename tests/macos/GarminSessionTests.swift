import XCTest
@testable import DeskIsle

final class GarminSessionTests: XCTestCase {
    private let oauth1 = #"{"domain":"garmin.cn","oauth_token":"test-only","oauth_token_secret":"test-only"}"#
    private let oauth2 = #"{"access_token":"test-only","refresh_token":"test-only"}"#

    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func legacy(_ root: URL) throws -> URL {
        let directory = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(oauth1.utf8).write(to: directory.appendingPathComponent("oauth1_token.json"))
        try Data(oauth2.utf8).write(to: directory.appendingPathComponent("oauth2_token.json"))
        return directory
    }
    func testImportOwnsPrivateCopyAndRemovalPreservesSource() throws {
        let root = try temporary(), source = try legacy(root)
        let store = GarminSessionStore(root: root.appendingPathComponent("owned"))
        let id = try store.importLegacy(directory: source)
        XCTAssertTrue(store.hasSession(id))
        let file = try store.file(for: id)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let parent = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(parent?.intValue, 0o700)
        try store.remove(id)
        XCTAssertFalse(store.hasSession(id))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("oauth1_token.json"), encoding: .utf8), oauth1)
        XCTAssertThrowsError(try store.file(for: "../../external"))
        XCTAssertThrowsError(try GarminSessionStore.validate(Data("[{},{}]".utf8)))
    }

    @MainActor
    func testProfileAdoptionAndDisconnectDoNotStoreOrDeleteExternalSecrets() throws {
        let root = try temporary(), source = try legacy(root)
        let store = GarminSessionStore(root: root.appendingPathComponent("owned"))
        let domain = "deskisle.tests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let settings = ConnectionSettings(preferences: preferences, inspectConnections: false, garminStore: store)
        settings.importGarminSession(source)
        let id = try XCTUnwrap(settings.profile.garmin.sessionID)
        XCTAssertNil(settings.profile.garmin.sessionDirectory)
        XCTAssertTrue(store.hasSession(id))
        let saved = try XCTUnwrap(preferences.data(forKey: ConnectionSettings.key))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("test-only"))
        settings.disconnectGarmin()
        XCTAssertFalse(settings.profile.garmin.enabled)
        XCTAssertNil(settings.profile.garmin.sessionID)
        XCTAssertFalse(store.hasSession(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("oauth2_token.json").path))
    }

    @MainActor
    func testLoginBridgeWaitsForMFAAndCancellationCannotAdoptSession() async throws {
        let root = try temporary()
        let store = GarminSessionStore(root: root.appendingPathComponent("owned"))
        let script = root.appendingPathComponent("auth_stub.py")
        let source = """
        import sys, json, pathlib
        value = json.loads(sys.stdin.readline())
        assert value['password'] == 'test-password'
        assert 'test-password' not in ' '.join(sys.argv)
        print('{"type":"mfa"}', flush=True)
        assert json.loads(sys.stdin.readline())['code'] == '123456'
        pathlib.Path(sys.argv[-1]).write_text('[\(oauth1),\(oauth2)]')
        print('{"type":"success"}', flush=True)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        let login = GarminLogin(store: store, runtime: .init(python: URL(fileURLWithPath: "/usr/bin/python3"),
                                                            script: script, packages: root))
        defer { login.cancel() }
        var adopted: String?
        login.start(email: "test@example.invalid", password: "test-password") { adopted = $0 }
        try await wait { login.state == .verification }
        XCTAssertNil(adopted)
        login.verify("123456")
        try await wait { login.state == .complete }
        XCTAssertTrue(store.hasSession(adopted))
        adopted = nil
        login.start(email: "test@example.invalid", password: "test-password") { adopted = $0 }
        try await wait { login.state == .verification }
        login.cancel()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(adopted)
        XCTAssertEqual(login.state, .idle)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path).count, 1)
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Login state did not advance")
    }
}
