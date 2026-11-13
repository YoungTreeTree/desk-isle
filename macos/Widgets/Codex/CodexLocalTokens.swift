import Foundation

// Use Dboard's cumulative-counter and fork-replay rules, with a local calendar day as the window.
enum CodexLocalTokens {
    private static let sessionMarker = Data("\"session_meta\"".utf8)
    private static let tokensMarker = Data("\"token_count\"".utf8)

    static func read(from start: Date, through end: Date, codexHome: URL? = nil) -> Int64? {
        let fileManager = FileManager.default
        let configuredHome = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { path in
            path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        }
        let home = codexHome ?? configuredHome ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        func timestamp(_ value: String?) -> Date? {
            guard let value else { return nil }
            return fractional.date(from: value) ?? seconds.date(from: value)
        }

        var scanned = Set<String>()
        var foundSessions = false
        var tokens: Int64 = 0
        for folder in ["sessions", "archived_sessions"] {
            let directory = home.appendingPathComponent(folder, isDirectory: true)
            guard fileManager.isReadableFile(atPath: directory.path),
                  let files = fileManager.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            foundSessions = true
            for case let file as URL in files {
                if Task.isCancelled { return nil }
                guard file.pathExtension == "jsonl", !scanned.contains(file.lastPathComponent),
                      let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                      (values.contentModificationDate ?? .distantPast) >= start,
                      let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
                scanned.insert(file.lastPathComponent)
                var firstMetadata = true
                var forkStart: Date?
                var previousTotal: Int64?
                for line in data.split(separator: 10) {
                    guard line.range(of: sessionMarker) != nil || line.range(of: tokensMarker) != nil,
                          let record = try? decoder.decode(Record.self, from: line) else { continue }
                    if record.type == "session_meta" && firstMetadata {
                        firstMetadata = false
                        if record.payload?.forkedFromId != nil {
                            forkStart = timestamp(record.payload?.timestamp ?? record.timestamp)
                        }
                    }
                    guard record.type == "event_msg", record.payload?.type == "token_count",
                          let total = record.payload?.info?.totalTokenUsage?.totalTokens, total >= 0,
                          let at = timestamp(record.timestamp) else { continue }
                    defer { previousTotal = total }
                    guard at >= start, at <= end,
                          forkStart.map({ at > $0.addingTimeInterval(1) }) ?? true else { continue }
                    if let previousTotal, total >= previousTotal {
                        tokens += total - previousTotal
                    } else if previousTotal == nil, record.payload?.info?.lastTokenUsage?.totalTokens == total {
                        tokens += total
                    }
                }
            }
        }
        return foundSessions ? tokens : nil
    }

    private struct Record: Decodable {
        let type: String
        let timestamp: String?
        let payload: Payload?

        struct Payload: Decodable {
            let type: String?
            let timestamp: String?
            let forkedFromId: String?
            let info: Info?
        }

        struct Info: Decodable {
            let totalTokenUsage: Usage?
            let lastTokenUsage: Usage?
        }

        struct Usage: Decodable { let totalTokens: Int64? }
    }
}
