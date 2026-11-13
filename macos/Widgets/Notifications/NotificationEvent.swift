import Foundation

struct NotificationEvent: Codable, Sendable {
    enum Kind: String, Codable {
        case post = "notification.post"
        case sessionOpened = "agent.session.opened"
        case sessionClosed = "agent.session.closed"
        case turnStarted = "agent.turn.started"
        case progress = "agent.turn.progress"
        case attentionRequested = "agent.attention.requested"
        case attentionResolved = "agent.attention.resolved"
        case turnFinished = "agent.turn.finished"
    }

    enum Level: String, Codable { case info, success, warning, error }
    enum RequestKind: String, Codable { case approval, question }
    enum Outcome: String, Codable { case completed, failed, interrupted }

    var version = 1
    var eventID = UUID().uuidString
    let type: Kind
    let source: String
    var sessionID: String?
    var turnID: String?
    var requestID: String?
    var requestKind: RequestKind?
    var outcome: Outcome?
    var project: String?
    var title: String?
    var body: String?
    var level: Level?
    var ttlMS: Int?

    enum CodingKeys: String, CodingKey {
        case version, type, source, outcome, project, title, body, level
        case eventID = "event_id"
        case sessionID = "session_id"
        case turnID = "turn_id"
        case requestID = "request_id"
        case requestKind = "request_kind"
        case ttlMS = "ttl_ms"
    }

    var isValid: Bool {
        guard version == 1, Self.validID(eventID), Self.validID(source), source.utf8.count <= 48 else { return false }
        if let ttlMS, !(1_000...60_000).contains(ttlMS) { return false }
        if type == .post { return !Self.displayText(title, limit: 80).isEmpty }
        guard Self.validID(sessionID) else { return false }
        if type == .sessionOpened || type == .sessionClosed { return true }
        guard Self.validID(turnID) else { return false }
        switch type {
        case .attentionRequested: return Self.validID(requestID) && requestKind != nil
        case .attentionResolved: return Self.validID(requestID)
        case .turnFinished: return outcome != nil
        default: return true
        }
    }

    static func displayText(_ text: String?, limit: Int) -> String {
        guard let text else { return "" }
        let words = text.prefix(limit * 4).split { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }
        return String(words.joined(separator: " ").prefix(limit))
    }

    static func sourceName(_ source: String) -> String {
        switch source {
        case "codex": "Codex"
        case "claude-code": "Claude Code"
        case "deskisle": "桌屿"
        default: source
        }
    }

    private static func validID(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
            (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 58 || $0 == 95 }
    }
}

struct NotificationSnapshot: Equatable {
    enum Style: String {
        case running, approval, question, info, success, warning, error, interrupted
    }

    struct Item: Equatable {
        let style: Style
        let source: String
        let sessionID: String?
        let title: String
        let body: String
        var project: String?
        var elapsedSeconds: Int?
    }

    let item: Item?
    let running: Int
    let waiting: Int
    var otherSessions: [Item] = []
    var expiresAt: Date?

    static let empty = Self(item: nil, running: 0, waiting: 0)

    var counts: String {
        [waiting > 0 ? "\(waiting) 待处理" : nil, running > 0 ? "\(running) 运行中" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct NotificationFeed {
    private struct SessionKey: Hashable {
        let source: String
        let id: String
    }

    private struct Waiting {
        let style: NotificationSnapshot.Style
        let body: String
        let added: Date
    }

    private struct Session {
        enum Phase { case idle, running, closed, finished }

        var title = ""
        var project: String?
        var updated: Date
        var turn: String?
        var startedAt: Date?
        var previousTurns: [String] = []
        var phase = Phase.idle
        var progress = ""
        var requests: [String: Waiting] = [:]

        var running: Bool { phase == .running }

        mutating func start(_ id: String) {
            if let turn {
                previousTurns.append(turn)
                if previousTurns.count > 16 { previousTurns.removeFirst() }
            }
            turn = id
            phase = .running
            startedAt = nil
            progress = ""
            requests.removeAll()
        }

        mutating func finish(as phase: Phase) {
            self.phase = phase
            requests.removeAll()
        }

        func item(for key: SessionKey, style: NotificationSnapshot.Style, body: String,
                  elapsedSeconds: Int? = nil) -> NotificationSnapshot.Item {
            let label = title.isEmpty ? project ?? NotificationEvent.sourceName(key.source) : title
            return .init(style: style, source: key.source, sessionID: key.id, title: label, body: body,
                         project: project, elapsedSeconds: elapsedSeconds)
        }
    }

    private struct Banner {
        let item: NotificationSnapshot.Item
        let expires: Date
    }

    private var sessions: [SessionKey: Session] = [:]
    private var banners: [Banner] = []
    private var recentIDs: [String] = []
    private var seenIDs: Set<String> = []

    mutating func receive(_ event: NotificationEvent, now: Date = Date()) {
        guard event.isValid else { return }
        let dedupKey = "\(event.source)/\(event.eventID)"
        guard seenIDs.insert(dedupKey).inserted else { return }
        recentIDs.append(dedupKey)
        if recentIDs.count > 512 { seenIDs.remove(recentIDs.removeFirst()) }
        prune(now: now)

        let title = NotificationEvent.displayText(event.title, limit: 80)
        let body = NotificationEvent.displayText(event.body, limit: 320)
        let project = NotificationEvent.displayText(event.project, limit: 48)
        if event.type == .post {
            let style: NotificationSnapshot.Style = switch event.level ?? .info {
            case .info: .info
            case .success: .success
            case .warning: .warning
            case .error: .error
            }
            showBanner(.init(style: style, source: event.source, sessionID: nil, title: title, body: body,
                             project: project.isEmpty ? nil : project),
                       expires: now.addingTimeInterval(Double(event.ttlMS ?? 8_000) / 1_000))
            return
        }

        guard let sessionID = event.sessionID else { return }
        let key = SessionKey(source: event.source, id: sessionID)
        var session = sessions[key] ?? Session(updated: now)
        if !project.isEmpty { session.project = project }
        if !title.isEmpty { session.title = title }
        let turnID = event.turnID
        if let turnID, session.previousTurns.contains(turnID) { return }
        switch event.type {
        case .post:
            return
        case .sessionOpened:
            break
        case .sessionClosed:
            if session.phase != .finished { session.finish(as: .closed) }
        case .turnStarted:
            guard let turnID else { return }
            if turnID != session.turn {
                session.start(turnID)
                if title.isEmpty && session.project != nil { session.title = "" }
                banners.removeAll { $0.item.source == key.source && $0.item.sessionID == key.id }
            } else if !session.running || session.startedAt != nil {
                return
            }
            session.startedAt = now
            session.progress = body
        case .progress:
            guard session.running, session.turn == turnID else { return }
            session.progress = body
        case .attentionRequested:
            guard let turnID, let requestID = event.requestID else { return }
            if session.turn == nil { session.start(turnID) }
            guard session.running, session.turn == turnID else { return }
            let style: NotificationSnapshot.Style = event.requestKind == .approval ? .approval : .question
            if session.requests[requestID] == nil, session.requests.count >= 16 { return }
            session.requests[requestID] = Waiting(style: style, body: body, added: now)
        case .attentionResolved:
            guard session.running, session.turn == turnID, let requestID = event.requestID else { return }
            session.requests.removeValue(forKey: requestID)
            if !body.isEmpty { session.progress = body }
        case .turnFinished:
            guard let turnID else { return }
            if session.turn == nil || (session.phase == .finished && session.turn != turnID) {
                session.start(turnID)
            }
            guard session.turn == turnID, session.phase != .finished else { return }
            session.finish(as: .finished)
            let style: NotificationSnapshot.Style = switch event.outcome {
            case .completed: .success
            case .failed: .error
            default: .interrupted
            }
            let elapsed = session.startedAt.map { Int(max(0, now.timeIntervalSince($0))) }
            showBanner(session.item(for: key, style: style, body: body, elapsedSeconds: elapsed),
                       expires: now.addingTimeInterval(8))
        }
        session.updated = now
        sessions[key] = session
        if sessions.count > 64, let oldest = sessions.min(by: { $0.value.updated < $1.value.updated }) {
            sessions.removeValue(forKey: oldest.key)
        }
    }

    mutating func snapshot(now: Date = Date(), includeBanners: Bool = true) -> NotificationSnapshot {
        prune(now: now)
        let waitingCount = sessions.values.reduce(0) { $0 + $1.requests.count }
        let waiting = sessions.compactMap { key, session -> (item: NotificationSnapshot.Item, date: Date)? in
            guard let request = session.requests.values.max(by: { $0.added < $1.added }) else { return nil }
            return (session.item(for: key, style: request.style, body: request.body), request.added)
        }.sorted { ($0.date, $0.item.source, $0.item.sessionID ?? "") > ($1.date, $1.item.source, $1.item.sessionID ?? "") }
        let running = sessions.filter { $0.value.running && $0.value.requests.isEmpty }
            .sorted { ($0.value.updated, $0.key.source, $0.key.id) > ($1.value.updated, $1.key.source, $1.key.id) }
            .map { key, session in session.item(for: key, style: .running, body: session.progress) }
        let banner = includeBanners
            ? (banners.last { $0.item.style == .error || $0.item.style == .warning } ?? banners.last)
            : nil
        let item = waiting.first?.item ?? banner?.item ?? running.first
        var snapshot = NotificationSnapshot(item: item, running: running.count, waiting: waitingCount)
        if waiting.isEmpty { snapshot.expiresAt = banner?.expires }
        if let item, item.style != .running {
            let others = (waiting.map(\.item) + running).filter { $0.source != item.source || $0.sessionID != item.sessionID }
            snapshot.otherSessions = Array(others.prefix(3))
        }
        return snapshot
    }

    private mutating func showBanner(_ item: NotificationSnapshot.Item, expires: Date) {
        banners.append(Banner(item: item, expires: expires))
        if banners.count > 16 { banners.removeFirst() }
    }

    private mutating func prune(now: Date) {
        banners.removeAll { $0.expires <= now }
        sessions = sessions.filter { now.timeIntervalSince($0.value.updated) < 4 * 60 * 60 }
    }
}
