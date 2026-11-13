import Foundation

/// App-owned sessions. Preferences contain only an opaque identifier, never tokens.
struct GarminSessionStore: Sendable {
    let root: URL
    init(root: URL = ConnectionPaths.support.appendingPathComponent("Connections/Garmin/sessions")) {
        self.root = root
    }
    func file(for id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw CocoaError(.fileReadCorruptFile) }
        return root.appendingPathComponent(id, isDirectory: true).appendingPathComponent("session.json")
    }
    func create() throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let id = UUID().uuidString
        try FileManager.default.createDirectory(at: try file(for: id).deletingLastPathComponent(),
                                                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return id
    }
    func hasSession(_ id: String?) -> Bool {
        guard let id, let url = try? file(for: id), let data = try? readBounded(url) else { return false }
        return (try? Self.validate(data)) != nil
    }
    func importLegacy(directory: URL) throws -> String {
        let parts = try ["oauth1_token.json", "oauth2_token.json"].map {
            try JSONSerialization.jsonObject(with: readBounded(directory.appendingPathComponent($0)))
        }
        let data = try JSONSerialization.data(withJSONObject: parts)
        try Self.validate(data)
        let id = try create()
        do {
            let url = try file(for: id)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return id
        } catch { try? remove(id); throw error }
    }
    func remove(_ id: String) throws {
        let directory = try file(for: id).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
    private func readBounded(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 131_072 else { throw CocoaError(.fileReadCorruptFile) }
        return try Data(contentsOf: url)
    }
    static func validate(_ data: Data) throws {
        guard data.count <= 131_072,
              let pair = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], pair.count == 2,
              pair[0]["domain"] as? String == "garmin.cn",
              ["oauth_token", "oauth_token_secret"].allSatisfy({ !(pair[0][$0] as? String ?? "").isEmpty }),
              ["access_token", "refresh_token"].allSatisfy({ !(pair[1][$0] as? String ?? "").isEmpty }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}
