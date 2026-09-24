import Foundation
import Observation

// MARK: - Mocks & Stubs

enum MockSupabaseState {
    static var recordedReplies: [(sendID: String, at: Date, from: String, snippet: String?)] = []
    static var attachedThreads: [(sendID: String, messageID: String, threadID: String)] = []
    static var throwScopeError = false
    static var throwSchemaError = false
    static var throwAttachError = false
}

enum SupabaseAPI {
    static var replyColumnsMissing: Bool { MockSupabaseState.throwSchemaError }

    static func attachThread(sendID: String, messageID: String, threadID: String) async throws {
        if MockSupabaseState.throwSchemaError { throw SupabaseError.schemaOutOfDate }
        if MockSupabaseState.throwAttachError { throw NSError(domain: "supabase", code: 500, userInfo: nil) }
        MockSupabaseState.attachedThreads.append((sendID, messageID, threadID))
    }

    static func recordReply(sendID: String, at date: Date, from sender: String, snippet: String?) async throws {
        if MockSupabaseState.throwSchemaError { throw SupabaseError.schemaOutOfDate }
        MockSupabaseState.recordedReplies.append((sendID, date, sender, snippet))
    }
}

enum SupabaseError: Error {
    case schemaOutOfDate
}

extension Error {
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

enum GmailAuthError: LocalizedError {
    case notConnected
    case insufficientScope
    case server(String)
}

enum GmailAuthStore {
    struct SentMessage: Decodable {
        let id: String
        let threadID: String
        enum CodingKeys: String, CodingKey {
            case id
            case threadID = "threadId"
        }
    }
}

struct MailSend: Identifiable {
    let id: String
    let contactID: String
    let sentAt: Date?
    var gmailMessageID: String?
    var gmailThreadID: String?
    var repliedAt: Date?
    var replyFrom: String?
    var replySnippet: String?

    var hasReplied: Bool { repliedAt != nil }

    func attaching(message: GmailAuthStore.SentMessage) -> MailSend {
        var copy = self
        copy.gmailMessageID = message.id
        copy.gmailThreadID = message.threadID
        return copy
    }
}

extension String {
    var htmlUnescaped: String {
        guard contains("&") else { return self }
        let named = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&nbsp;": " ", "&hellip;": "…", "&mdash;": "—",
            "&ndash;": "–", "&rsquo;": "'", "&lsquo;": "'",
            "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}"
        ]
        var result = self
        for (entity, character) in named {
            result = result.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        guard let pattern = try? Regex(#"&#(x?)([0-9A-Fa-f]+);"#) else { return result }
        while let match = result.firstMatch(of: pattern) {
            let prefix = match.output[1].substring ?? ""
            let hexOrDec = match.output[2].substring ?? ""
            let radix = prefix.isEmpty ? 10 : 16
            guard let code = UInt32(hexOrDec, radix: radix),
                  let scalar = Unicode.Scalar(code) else {
                result.replaceSubrange(match.range, with: "")
                continue
            }
            result.replaceSubrange(match.range, with: String(Character(scalar)))
        }
        return result
    }
}

// MARK: - ReplySync Engine Under Test

@MainActor
final class ReplySync {
    struct Outcome {
        var recovered = 0
        var replies = 0
        var bounced = 0
        var failed = 0
        var changedAnything: Bool { recovered > 0 || replies > 0 }
    }

    struct Progress {
        var label = ""
        var done = 0
        var total = 0
        var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    }

    private(set) var isSyncing = false
    private(set) var progress = Progress()
    private(set) var lastSyncedAt: Date?
    private(set) var lastOutcome: Outcome?
    private(set) var needsReconnect = false
    private(set) var needsMigration = false
    var errorMessage: String?
    private(set) var bouncedContactIDs: Set<String> = []
    private var unrecoverableSendIDs: Set<String> = []

    var reader: ((String, [URLQueryItem]) async throws -> Data)?

    nonisolated private static let checkWindow: TimeInterval = 120 * 24 * 60 * 60
    nonisolated private static let recoveryWindow: TimeInterval = 10 * 60
    nonisolated private static let concurrency = 5

    @discardableResult
    func run(sends: [MailSend],
             emailByContact: [String: String],
             excludingContactIDs: Set<String> = []) async -> Outcome {
        guard !isSyncing, reader != nil else { return Outcome() }
        isSyncing = true
        needsReconnect = false
        needsMigration = SupabaseAPI.replyColumnsMissing
        var outcome = Outcome()
        var completed = false
        defer {
            isSyncing = false
            progress = Progress()
            if completed {
                lastSyncedAt = .now
                lastOutcome = outcome
            }
        }

        var sends = sends
        do {
            let recovered = try await recoverThreadIDs(in: sends, emailByContact: emailByContact)
            outcome.recovered = recovered.count
            outcome.failed += recovered.failed
            sends = sends.map { send in
                guard let message = recovered.threadIDs[send.id] else { return send }
                return send.attaching(message: message)
            }

            let checked = try await checkForReplies(in: sends, excludingContactIDs: excludingContactIDs)
            outcome.replies = checked.replies
            outcome.bounced = checked.bounced
            outcome.failed += checked.failed
            bouncedContactIDs = checked.bouncedContacts
            completed = true
        } catch let error as GmailAuthError where error.isScopeFailure {
            needsReconnect = true
        } catch let error as SupabaseError where error.isSchemaOutOfDate {
            needsMigration = true
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
        return outcome
    }

    private struct Recovered {
        var threadIDs: [String: GmailAuthStore.SentMessage] = [:]
        var failed = 0
        var count: Int { threadIDs.count }
    }

    private enum RecoverResult {
        case attached(sendID: String, message: GmailAuthStore.SentMessage)
        case notFound(sendID: String)
        case skipped
        case failed
    }

    private func recoverThreadIDs(in sends: [MailSend],
                                  emailByContact: [String: String]) async throws -> Recovered {
        guard let reader else { throw GmailAuthError.notConnected }
        let targets = sends.filter {
            $0.gmailThreadID == nil && $0.sentAt != nil && !unrecoverableSendIDs.contains($0.id)
        }
        guard !targets.isEmpty else { return Recovered() }

        progress = Progress(label: "Matching sent mail", done: 0, total: targets.count)
        var result = Recovered()

        for chunk in stride(from: 0, to: targets.count, by: Self.concurrency).map({
            Array(targets[$0..<min($0 + Self.concurrency, targets.count)])
        }) {
            try Task.checkCancellation()
            let chunkResults = try await withThrowingTaskGroup(of: RecoverResult.self) { group in
                for send in chunk {
                    group.addTask {
                        guard let sentAt = send.sentAt,
                              let recipient = emailByContact[send.contactID],
                              Self.isSearchable(recipient) else {
                            return .skipped
                        }
                        do {
                            guard let message = try await Self.findSentMessage(to: recipient, around: sentAt, reader: reader) else {
                                return .notFound(sendID: send.id)
                            }
                            return .attached(sendID: send.id, message: message)
                        } catch let error as GmailAuthError where error.isScopeFailure {
                            throw error
                        } catch let error as SupabaseError where error.isSchemaOutOfDate {
                            throw error
                        } catch {
                            return .failed
                        }
                    }
                }
                var outcomes: [RecoverResult] = []
                for try await outcome in group {
                    outcomes.append(outcome)
                }
                return outcomes
            }

            for outcome in chunkResults {
                switch outcome {
                case .attached(let sendID, let message):
                    do {
                        try await SupabaseAPI.attachThread(sendID: sendID,
                                                           messageID: message.id,
                                                           threadID: message.threadID)
                        result.threadIDs[sendID] = message
                    } catch {
                        result.failed += 1
                    }
                case .notFound(let sendID):
                    unrecoverableSendIDs.insert(sendID)
                case .skipped:
                    break
                case .failed:
                    result.failed += 1
                }
            }
            progress.done += chunk.count
        }
        return result
    }

    nonisolated static func isSafePathComponent(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy(\.isHexDigit)
    }

    nonisolated static func isSearchable(_ email: String) -> Bool {
        guard !email.isEmpty,
              let atIndex = email.firstIndex(of: "@"),
              atIndex != email.startIndex,
              email.index(after: atIndex) != email.endIndex else {
            return false
        }
        return email.allSatisfy { !$0.isWhitespace && $0 != "\"" && $0 != "(" && $0 != ")" }
    }

    nonisolated private static func findSentMessage(to recipient: String,
                                                    around date: Date,
                                                    reader: (String, [URLQueryItem]) async throws -> Data) async throws -> GmailAuthStore.SentMessage? {
        let after = Int(date.addingTimeInterval(-recoveryWindow).timeIntervalSince1970)
        let before = Int(date.addingTimeInterval(recoveryWindow).timeIntervalSince1970)
        let data = try await reader("messages", [
            URLQueryItem(name: "q", value: "in:sent to:\(recipient) after:\(after) before:\(before)"),
            URLQueryItem(name: "maxResults", value: "2")
        ])
        struct Listing: Decodable { let messages: [GmailAuthStore.SentMessage]? }
        return try JSONDecoder().decode(Listing.self, from: data).messages?.first
    }

    private struct Checked {
        var replies = 0
        var bounced = 0
        var failed = 0
        var bouncedContacts: Set<String> = []
    }

    private enum CheckResult {
        case reply(sendID: String, at: Date, from: String, snippet: String?)
        case bounce(contactID: String)
        case silent
        case failed
    }

    nonisolated private static func findIncomingThreadIDs(after date: Date,
                                                          reader: (String, [URLQueryItem]) async throws -> Data) async throws -> Set<String>? {
        let afterSeconds = Int(date.timeIntervalSince1970)
        let data = try await reader("messages", [
            URLQueryItem(name: "q", value: "after:\(afterSeconds) -from:me"),
            URLQueryItem(name: "maxResults", value: "100")
        ])
        struct MsgItem: Decodable {
            let id: String
            let threadId: String
        }
        struct Listing: Decodable {
            let messages: [MsgItem]?
        }
        let list = try JSONDecoder().decode(Listing.self, from: data)
        return Set(list.messages?.map(\.threadId) ?? [])
    }

    private func checkForReplies(in sends: [MailSend],
                                  excludingContactIDs: Set<String> = []) async throws -> Checked {
        guard let reader else { throw GmailAuthError.notConnected }
        let cutoff = Date().addingTimeInterval(-Self.checkWindow)
        let activeSends = sends.filter {
            $0.gmailThreadID != nil &&
            !$0.hasReplied &&
            !excludingContactIDs.contains($0.contactID) &&
            ($0.sentAt ?? .distantPast) > cutoff
        }
        guard !activeSends.isEmpty else { return Checked() }

        let targets: [MailSend]
        if let lastSync = lastSyncedAt,
           Date().timeIntervalSince(lastSync) < 7 * 24 * 60 * 60,
           let incomingThreadIDs = try? await Self.findIncomingThreadIDs(after: lastSync.addingTimeInterval(-15 * 60), reader: reader) {
            targets = activeSends.filter { send in
                guard let threadID = send.gmailThreadID else { return false }
                return incomingThreadIDs.contains(threadID)
            }
        } else {
            targets = activeSends
        }

        guard !targets.isEmpty else { return Checked() }

        progress = Progress(label: "Checking for replies", done: 0, total: targets.count)
        var result = Checked()

        for chunk in stride(from: 0, to: targets.count, by: Self.concurrency).map({
            Array(targets[$0..<min($0 + Self.concurrency, targets.count)])
        }) {
            try Task.checkCancellation()
            let chunkResults = try await withThrowingTaskGroup(of: CheckResult.self) { group in
                for send in chunk {
                    group.addTask {
                        guard let threadID = send.gmailThreadID else { return .silent }
                        do {
                            switch try await Self.firstResponse(inThread: threadID, after: send.sentAt, reader: reader) {
                            case .reply(let date, let sender, let snippet):
                                return .reply(sendID: send.id, at: date, from: sender, snippet: snippet)
                            case .bounce:
                                return .bounce(contactID: send.contactID)
                            case .silent:
                                return .silent
                            }
                        } catch let error as GmailAuthError where error.isScopeFailure {
                            throw error
                        } catch let error as SupabaseError where error.isSchemaOutOfDate {
                            throw error
                        } catch {
                            return .failed
                        }
                    }
                }
                var outcomes: [CheckResult] = []
                for try await outcome in group {
                    outcomes.append(outcome)
                }
                return outcomes
            }

            for outcome in chunkResults {
                switch outcome {
                case .reply(let sendID, let date, let sender, let snippet):
                    do {
                        try await SupabaseAPI.recordReply(sendID: sendID, at: date,
                                                          from: sender, snippet: snippet)
                        result.replies += 1
                    } catch {
                        result.failed += 1
                    }
                case .bounce(let contactID):
                    result.bounced += 1
                    result.bouncedContacts.insert(contactID)
                case .silent:
                    break
                case .failed:
                    result.failed += 1
                }
            }
            progress.done += chunk.count
        }
        return result
    }

    private enum ThreadResponse {
        case reply(at: Date, from: String, snippet: String?)
        case bounce
        case silent
    }

    nonisolated private static func firstResponse(inThread threadID: String,
                                                  after sentAt: Date?,
                                                  reader: (String, [URLQueryItem]) async throws -> Data) async throws -> ThreadResponse {
        guard isSafePathComponent(threadID) else { return .silent }

        let data = try await reader("threads/\(threadID)", [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "fields", value: "messages(id,labelIds,snippet,internalDate,payload/headers)"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "Date"),
            URLQueryItem(name: "metadataHeaders", value: "Auto-Submitted"),
            URLQueryItem(name: "metadataHeaders", value: "Precedence")
        ])
        let thread = try JSONDecoder().decode(GmailThread.self, from: data)

        if thread.messages.count <= 1 && (thread.messages.first?.isOurs ?? false) {
            return .silent
        }

        var sawBounce = false
        for message in thread.messages.sorted(by: { $0.date < $1.date }) {
            guard !message.isOurs else { continue }
            if let sentAt, message.date <= sentAt { continue }
            if message.isBounce { sawBounce = true; continue }
            if message.isAutomated { continue }
            guard let from = message.from, !from.isEmpty else { continue }
            return .reply(at: message.date,
                          from: from,
                          snippet: message.snippet?.htmlUnescaped)
        }
        return sawBounce ? .bounce : .silent
    }
}

private struct GmailThread: Decodable {
    let messages: [Message]

    struct Message: Decodable {
        let id: String
        let labelIds: [String]?
        let snippet: String?
        let internalDate: String?
        let payload: Payload?

        struct Payload: Decodable {
            let headers: [Header]?
            struct Header: Decodable { let name: String; let value: String }
        }

        var date: Date {
            guard let ms = internalDate.flatMap(Double.init) else { return .distantPast }
            return Date(timeIntervalSince1970: ms / 1000)
        }

        var isOurs: Bool {
            let labels = labelIds ?? []
            return labels.contains("SENT") || labels.contains("DRAFT")
        }

        var from: String? { header("From") }

        var isAutomated: Bool {
            if let auto = header("Auto-Submitted")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), auto != "no" {
                return true
            }
            if let precedence = header("Precedence")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               ["bulk", "auto_reply", "junk", "list"].contains(precedence) {
                return true
            }
            let sender = from ?? ""
            return sender.localizedCaseInsensitiveContains("no-reply")
                || sender.localizedCaseInsensitiveContains("noreply")
                || sender.localizedCaseInsensitiveContains("do-not-reply")
                || sender.localizedCaseInsensitiveContains("donotreply")
        }

        var isBounce: Bool {
            let sender = (from ?? "").lowercased()
            return sender.contains("mailer-daemon") || sender.contains("postmaster")
        }

        private func header(_ name: String) -> String? {
            payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }
}

private extension GmailAuthError {
    var isScopeFailure: Bool {
        if case .insufficientScope = self { return true }
        return false
    }
}

private extension SupabaseError {
    var isSchemaOutOfDate: Bool {
        if case .schemaOutOfDate = self { return true }
        return false
    }
}

// MARK: - Test Suite Runner

@MainActor
func runEndToEndTests() async {
    print("\n==========================================")
    print("Running End-to-End ReplySync Lifecycle Tests")
    print("==========================================\n")

    var passed = 0
    var failed = 0

    func check(_ name: String, block: () async throws -> Void) async {
        do {
            try await block()
            passed += 1
            print("  ✓ \(name)")
        } catch {
            failed += 1
            print("  ✗ \(name): \(error)")
        }
    }

    func threadJSON(messages: [(id: String, isOurs: Bool, isBounce: Bool, isAuto: Bool, from: String, snippet: String, date: Double)]) -> Data {
        var msgs: [[String: Any]] = []
        for m in messages {
            var headers: [[String: String]] = [["name": "From", "value": m.from]]
            if m.isAuto { headers.append(["name": "Auto-Submitted", "value": "auto-replied"]) }
            let msg: [String: Any] = [
                "id": m.id,
                "labelIds": m.isOurs ? ["SENT"] : ["INBOX"],
                "snippet": m.snippet,
                "internalDate": String(Int(m.date * 1000)),
                "payload": ["headers": headers]
            ]
            msgs.append(msg)
        }
        return try! JSONSerialization.data(withJSONObject: ["messages": msgs])
    }

    // MARK: - Test 1: Delta Sync avoids thread calls when no incoming mail

    await check("Delta sync avoids thread.get when delta search finds 0 incoming messages") {
        let sync = ReplySync()
        var requestedPaths: [String] = []

        let send1 = MailSend(id: "s1", contactID: "r1", sentAt: Date().addingTimeInterval(-3600),
                             gmailMessageID: "m1", gmailThreadID: "18d85fbc294a6e01")
        let send2 = MailSend(id: "s2", contactID: "r2", sentAt: Date().addingTimeInterval(-7200),
                             gmailMessageID: "m2", gmailThreadID: "18d85fbc294a6e02")

        sync.reader = { path, _ in
            requestedPaths.append(path)
            return threadJSON(messages: [("m1", true, false, false, "me@gmail.com", "hey", 1000)])
        }

        _ = await sync.run(sends: [send1, send2], emailByContact: [:])
        requestedPaths.removeAll()

        sync.reader = { path, _ in
            requestedPaths.append(path)
            if path == "messages" {
                return "{\"messages\": []}".data(using: .utf8)!
            }
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected thread request: \(path)"])
        }

        let outcome = await sync.run(sends: [send1, send2], emailByContact: [:])
        if outcome.replies != 0 || outcome.failed != 0 {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Outcome should be 0 replies"])
        }
        if requestedPaths != ["messages"] {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected only 1 'messages' query, got \(requestedPaths)"])
        }
    }

    // MARK: - Test 2: Delta Sync fetches only matching threads

    await check("Delta sync fetches only matching active thread when delta finds mail") {
        let sync = ReplySync()
        var requestedPaths: [String] = []

        let send1 = MailSend(id: "s1", contactID: "r1", sentAt: Date().addingTimeInterval(-3600),
                             gmailMessageID: "m1", gmailThreadID: "18d85fbc294a6e03")
        let send2 = MailSend(id: "s2", contactID: "r2", sentAt: Date().addingTimeInterval(-7200),
                             gmailMessageID: "m2", gmailThreadID: "18d85fbc294a6e04")

        sync.reader = { path, _ in
            requestedPaths.append(path)
            return threadJSON(messages: [("m1", true, false, false, "me@gmail.com", "hey", 1000)])
        }
        _ = await sync.run(sends: [send1, send2], emailByContact: [:])
        requestedPaths.removeAll()

        sync.reader = { path, _ in
            requestedPaths.append(path)
            if path == "messages" {
                let json = """
                {
                    "messages": [
                        {"id": "in1", "threadId": "18d85fbc294a6e03"},
                        {"id": "in2", "threadId": "18d85fbc294a6e05"}
                    ]
                }
                """
                return json.data(using: .utf8)!
            }
            if path == "threads/18d85fbc294a6e03" {
                return threadJSON(messages: [
                    ("m_sent", true, false, false, "me@gmail.com", "Intro", 1000),
                    ("m_reply", false, false, false, "contact@corp.com", "Sounds good!", Date().timeIntervalSince1970 + 10)
                ])
            }
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected path: \(path)"])
        }

        MockSupabaseState.recordedReplies.removeAll()
        let outcome = await sync.run(sends: [send1, send2], emailByContact: [:])

        if outcome.replies != 1 {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected 1 reply, got \(outcome.replies)"])
        }
        if requestedPaths != ["messages", "threads/18d85fbc294a6e03"] {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected ['messages', 'threads/18d85fbc294a6e03'], got \(requestedPaths)"])
        }
        if MockSupabaseState.recordedReplies.count != 1 || MockSupabaseState.recordedReplies.first?.sendID != "s1" {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Supabase recordReply failed"])
        }
    }

    // MARK: - Test 3: Unrecoverable sends cached

    await check("Unrecoverable sends are not re-searched on subsequent runs") {
        let sync = ReplySync()
        var sentQueriesCount = 0

        let orphanSend = MailSend(id: "orphan_1", contactID: "r1", sentAt: Date().addingTimeInterval(-1000),
                                  gmailMessageID: nil, gmailThreadID: nil)

        sync.reader = { path, query in
            if path == "messages" {
                let q = query.first(where: { $0.name == "q" })?.value ?? ""
                if q.contains("in:sent") {
                    sentQueriesCount += 1
                    return "{\"messages\": []}".data(using: .utf8)!
                }
            }
            return "{\"messages\": []}".data(using: .utf8)!
        }

        let emailMap = ["r1": "contact@corp.com"]
        _ = await sync.run(sends: [orphanSend], emailByContact: emailMap)
        if sentQueriesCount != 1 {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected 1 sent query, got \(sentQueriesCount)"])
        }

        _ = await sync.run(sends: [orphanSend], emailByContact: emailMap)
        if sentQueriesCount != 1 {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected 0 additional sent queries (cached unrecoverable), got \(sentQueriesCount)"])
        }
    }

    // MARK: - Test 4: Excluding contact IDs

    await check("Excluding known invalid contact IDs skips thread checks") {
        let sync = ReplySync()
        var checkedThreads: [String] = []

        let sendValid = MailSend(id: "s1", contactID: "r_valid", sentAt: Date().addingTimeInterval(-3600),
                                 gmailMessageID: "m1", gmailThreadID: "18d85fbc294a6e06")
        let sendInvalid = MailSend(id: "s2", contactID: "r_dead", sentAt: Date().addingTimeInterval(-3600),
                                   gmailMessageID: "m2", gmailThreadID: "18d85fbc294a6e07")

        sync.reader = { path, _ in
            if path.starts(with: "threads/") {
                checkedThreads.append(path)
            }
            return threadJSON(messages: [("m", true, false, false, "me@gmail.com", "hi", 1000)])
        }

        _ = await sync.run(sends: [sendValid, sendInvalid],
                           emailByContact: [:],
                           excludingContactIDs: ["r_dead"])

        if checkedThreads != ["threads/18d85fbc294a6e06"] {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected only 18d85fbc294a6e06, got \(checkedThreads)"])
        }
    }

    // MARK: - Test 5: Insufficient scope error handling

    await check("Insufficient scope triggers needsReconnect") {
        let sync = ReplySync()
        let send = MailSend(id: "s1", contactID: "r1", sentAt: Date().addingTimeInterval(-3600),
                            gmailMessageID: "m1", gmailThreadID: "18d85fbc294a6e01")
        sync.reader = { _, _ in
            throw GmailAuthError.insufficientScope
        }

        _ = await sync.run(sends: [send], emailByContact: [:])
        if !sync.needsReconnect {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected needsReconnect = true"])
        }
    }

    // MARK: - Test 6: Thread Recovery followed by Immediate Reply Detection

    await check("Thread recovery and immediate reply detection in single run") {
        MockSupabaseState.attachedThreads.removeAll()
        MockSupabaseState.recordedReplies.removeAll()

        let sync = ReplySync()
        let orphanSend = MailSend(id: "orphan_rec", contactID: "r_rec", sentAt: Date().addingTimeInterval(-1000),
                                  gmailMessageID: nil, gmailThreadID: nil)

        let now = Date().timeIntervalSince1970
        sync.reader = { path, query in
            if path == "messages" {
                let json = """
                {"messages": [{"id": "recovered_msg_1", "threadId": "18d85fbc294a6e99"}]}
                """
                return json.data(using: .utf8)!
            }
            if path == "threads/18d85fbc294a6e99" {
                return threadJSON(messages: [
                    ("recovered_msg_1", true, false, false, "me@gmail.com", "Mail", now - 500),
                    ("reply_1", false, false, false, "contact@corp.com", "Thanks for reaching out!", now + 10)
                ])
            }
            throw NSError(domain: "test", code: 1, userInfo: nil)
        }

        let outcome = await sync.run(sends: [orphanSend], emailByContact: ["r_rec": "contact@corp.com"])
        if outcome.recovered != 1 {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected recovered == 1, got \(outcome.recovered)"])
        }
        if outcome.replies != 1 {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected replies == 1, got \(outcome.replies)"])
        }
        if MockSupabaseState.attachedThreads.count != 1 || MockSupabaseState.attachedThreads.first?.threadID != "18d85fbc294a6e99" {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Thread attachment not recorded in Supabase"])
        }
        if MockSupabaseState.recordedReplies.count != 1 || MockSupabaseState.recordedReplies.first?.sendID != "orphan_rec" {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Reply not recorded in Supabase"])
        }
    }

    // MARK: - Test 7: Network 500/429 resilience across chunks

    await check("Partial HTTP 500 error increments failed count without aborting other threads") {
        let sync = ReplySync()
        let now = Date().timeIntervalSince1970

        let sends = (0..<10).map { i in
            MailSend(id: "send_\(i)", contactID: "r_\(i)", sentAt: Date().addingTimeInterval(-3600),
                     gmailMessageID: "msg_\(i)", gmailThreadID: "18d85fbc294a6e\(String(format: "%02d", i))")
        }

        sync.reader = { path, _ in
            if path == "threads/18d85fbc294a6e03" {
                // Simulate 500 or 429 server rate limit on thread 3
                throw GmailAuthError.server("429 Too Many Requests")
            }
            if path == "threads/18d85fbc294a6e05" {
                // Thread 5 has a reply!
                return threadJSON(messages: [
                    ("m_sent", true, false, false, "me@gmail.com", "Hey", now - 3600),
                    ("m_rep", false, false, false, "hiring@corp.com", "Yes, let's talk!", now + 10)
                ])
            }
            return threadJSON(messages: [("m_sent", true, false, false, "me@gmail.com", "Hey", now - 3600)])
        }

        let outcome = await sync.run(sends: sends, emailByContact: [:])
        if outcome.failed != 1 {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected exactly 1 failed, got \(outcome.failed)"])
        }
        if outcome.replies != 1 {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected 1 reply despite partial failure, got \(outcome.replies)"])
        }
    }

    // MARK: - Test 8: Supabase schema error triggers needsMigration

    await check("Supabase schemaOutOfDate aborts and sets needsMigration") {
        MockSupabaseState.throwSchemaError = true
        defer { MockSupabaseState.throwSchemaError = false }

        let sync = ReplySync()
        let send = MailSend(id: "s1", contactID: "r1", sentAt: Date().addingTimeInterval(-3600),
                            gmailMessageID: "m1", gmailThreadID: "18d85fbc294a6e01")

        sync.reader = { path, _ in
            return threadJSON(messages: [
                ("m_sent", true, false, false, "me@gmail.com", "Hey", 1000),
                ("m_rep", false, false, false, "hiring@corp.com", "Yes!", 2000)
            ])
        }

        _ = await sync.run(sends: [send], emailByContact: [:])
        if !sync.needsMigration {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected needsMigration = true"])
        }
    }

    // MARK: - Test 9: Delta search network failure falls back to active sends

    await check("Delta search network error smoothly falls back to full active sends check") {
        let sync = ReplySync()
        let now = Date().timeIntervalSince1970
        let send = MailSend(id: "s1", contactID: "r1", sentAt: Date().addingTimeInterval(-3600),
                            gmailMessageID: "m1", gmailThreadID: "18d85fbc294a6e01")

        // First run establishes lastSyncedAt
        sync.reader = { _, _ in
            return threadJSON(messages: [("m1", true, false, false, "me@gmail.com", "hey", now - 3600)])
        }
        _ = await sync.run(sends: [send], emailByContact: [:])

        // Second run: messages delta query throws network error!
        var checkedFallbackThread = false
        sync.reader = { path, _ in
            if path == "messages" {
                throw NSError(domain: "network", code: -1009, userInfo: nil)
            }
            if path == "threads/18d85fbc294a6e01" {
                checkedFallbackThread = true
                return threadJSON(messages: [
                    ("m1", true, false, false, "me@gmail.com", "hey", now - 3600),
                    ("m2", false, false, false, "contact@corp.com", "Interested!", now + 10)
                ])
            }
            throw NSError(domain: "test", code: 1, userInfo: nil)
        }

        let outcome = await sync.run(sends: [send], emailByContact: [:])
        if !checkedFallbackThread {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected fallback to inspect active thread when delta search fails"])
        }
        if outcome.replies != 1 {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected 1 reply from fallback"])
        }
    }

    // MARK: - Test 10: Task cancellation cleanup

    await check("Task cancellation stops cleanly without stamping lastSyncedAt") {
        let sync = ReplySync()
        let sends = (0..<20).map { i in
            MailSend(id: "s_\(i)", contactID: "r_\(i)", sentAt: Date().addingTimeInterval(-3600),
                     gmailMessageID: "m_\(i)", gmailThreadID: "18d85fbc294a6e\(String(format: "%02d", i))")
        }

        sync.reader = { _, _ in
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            return threadJSON(messages: [("m", true, false, false, "me@gmail.com", "hi", 1000)])
        }

        let task = Task {
            await sync.run(sends: sends, emailByContact: [:])
        }

        // Let it start, then cancel
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        _ = await task.value

        if sync.isSyncing {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "isSyncing should be false after cancellation"])
        }
        if sync.lastSyncedAt != nil {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "lastSyncedAt should NOT be stamped on cancelled run"])
        }
    }

    print("\n==========================================")
    print("End-to-End Results: \(passed) passed, \(failed) failed")
    print("==========================================\n")
    if failed > 0 {
        exit(1)
    }
}

await runEndToEndTests()
