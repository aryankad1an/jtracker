import Foundation
import Observation

/// Finds out which cold mails were answered, by reading the mailbox they were
/// sent from.
///
/// The signal is Gmail's own thread id, not a match on sender and time. Every
/// reply lands in the thread of the message it answers, whoever sends it — so a
/// recruiter answering from their personal address, or a colleague picking up a
/// mail sent to `recruiting@`, is still detected. Matching inbound mail by
/// address would miss both, and would count a newsletter from the same address
/// as a reply.
///
/// Two passes, in order:
///
/// 1. **Recover.** Sends recorded before the app captured thread ids have none.
///    Their messages are still in Sent, and we know exactly who each one went to
///    and when, so a one-off search recovers the thread id — this is a lookup,
///    not a guess. It runs once per send and never again.
/// 2. **Check.** For every send that has a thread and no reply yet, read the
///    thread's headers and look for a message that isn't ours.
///
/// Like `MailQueue`, this holds no reference to the auth or data stores: it is
/// handed a `reader` closure by `RootView`, so the refresh token never leaves
/// `GmailAuthStore`.
@Observable
final class ReplySync {

    /// What one sync did. `failed` counts requests that errored but didn't stop
    /// the run — a single unreadable thread shouldn't abandon the other hundred.
    struct Outcome {
        var recovered = 0
        var replies = 0
        var bounced = 0
        var failed = 0

        var changedAnything: Bool { recovered > 0 || replies > 0 }
    }

    /// Progress, for the UI. `total` is 0 while idle.
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

    /// Set when Gmail refuses the read for want of the `gmail.readonly` scope —
    /// i.e. the stored token predates reply tracking. The UI turns this into a
    /// "reconnect Gmail" prompt rather than an error alert, because that's the
    /// only thing that fixes it.
    private(set) var needsReconnect = false

    /// Set when the database is missing the reply-tracking columns — the app is
    /// newer than the schema, and the fix is the migration in the README.
    private(set) var needsMigration = false
    var errorMessage: String?

    /// Recruiter ids whose thread came back with a delivery failure. Recomputed
    /// every sync from the thread itself (never stored), so it can't go stale —
    /// Quick Actions offers these up to be marked invalid.
    private(set) var bouncedRecruiterIDs: Set<String> = []

    /// Performs an authorized Gmail GET. Injected so this type stays independent
    /// of how the account is authenticated.
    var reader: ((String, [URLQueryItem]) async throws -> Data)?

    /// How far back to keep checking unanswered sends. A cold mail that has been
    /// silent for four months isn't about to be answered, and re-reading those
    /// threads on every sync costs a request each, forever.
    private static let checkWindow: TimeInterval = 120 * 24 * 60 * 60

    /// How wide a net to cast around a send's recorded timestamp when recovering
    /// its thread. Wide enough to absorb clock skew between the app and Gmail,
    /// far narrower than the gap between two mails to the same person.
    private static let recoveryWindow: TimeInterval = 10 * 60

    /// Requests in flight at once. Gmail's per-user ceiling is far higher; this is
    /// about not saturating a phone's connection while the user is looking at a
    /// list that's refreshing underneath them.
    private static let concurrency = 5

    // MARK: - Running

    /// Recover missing thread ids, then look for replies. Safe to call often:
    /// each send is recovered once and checked only while it's unanswered.
    ///
    /// - Parameter emailByRecruiter: recipient address per recruiter id, needed to
    ///   search Sent for the original message.
    @discardableResult
    func run(sends: [MailSend], emailByRecruiter: [String: String]) async -> Outcome {
        guard !isSyncing, reader != nil else { return Outcome() }
        isSyncing = true
        needsReconnect = false
        needsMigration = SupabaseAPI.replyColumnsMissing
        var outcome = Outcome()
        var completed = false
        defer {
            isSyncing = false
            progress = Progress()
            // Only stamp a completed run. A cancelled one has checked nothing, and
            // "Checked just now" would be a lie that also hides the real state.
            if completed {
                lastSyncedAt = .now
                lastOutcome = outcome
            }
        }

        var sends = sends
        do {
            let recovered = try await recoverThreadIDs(in: sends, emailByRecruiter: emailByRecruiter)
            outcome.recovered = recovered.count
            outcome.failed += recovered.failed
            // Fold the recovered ids back in so this run can check them straight
            // away, instead of finding a reply only on the next sync.
            sends = sends.map { send in
                guard let message = recovered.threadIDs[send.id] else { return send }
                return send.attaching(message: message)
            }

            let checked = try await checkForReplies(in: sends)
            outcome.replies = checked.replies
            outcome.bounced = checked.bounced
            outcome.failed += checked.failed
            bouncedRecruiterIDs = checked.bouncedRecruiters
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

    // MARK: - Pass 1: recover thread ids for older sends

    private struct Recovered {
        var threadIDs: [String: GmailAuthStore.SentMessage] = [:]
        var failed = 0
        var count: Int { threadIDs.count }
    }

    private func recoverThreadIDs(in sends: [MailSend],
                                  emailByRecruiter: [String: String]) async throws -> Recovered {
        let targets = sends.filter { $0.gmailThreadID == nil && $0.sentAt != nil }
        guard !targets.isEmpty else { return Recovered() }

        progress = Progress(label: "Matching sent mail", done: 0, total: targets.count)
        var result = Recovered()

        try await forEachChunk(targets) { send in
            guard let sentAt = send.sentAt,
                  let recipient = emailByRecruiter[send.recruiterID],
                  Self.isSearchable(recipient) else {
                return
            }
            do {
                guard let message = try await self.findSentMessage(to: recipient, around: sentAt) else { return }
                try await SupabaseAPI.attachThread(sendID: send.id,
                                                   messageID: message.id,
                                                   threadID: message.threadID)
                result.threadIDs[send.id] = message
            } catch let error as GmailAuthError where error.isScopeFailure {
                throw error
            } catch let error as SupabaseError where error.isSchemaOutOfDate {
                throw error
            } catch {
                result.failed += 1
            }
        }
        return result
    }

    /// Whether a value is safe to interpolate into an API path: letters and
    /// digits only, which is what Gmail's message and thread ids are.
    private static func isSafePathComponent(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy(\.isHexDigit)
    }

    /// Whether an address is safe to drop into a Gmail search expression. A
    /// stored address with a space or a quote in it would change the shape of the
    /// query rather than the value being searched for, so those rows are skipped
    /// instead: no thread id is worse than the wrong thread id.
    private static func isSearchable(_ email: String) -> Bool {
        !email.isEmpty
            && email.contains("@")
            && email.allSatisfy { !$0.isWhitespace && $0 != "\"" && $0 != "(" && $0 != ")" }
    }

    /// The Sent copy of one mail: an exact `to:` plus a tight time window, which
    /// resolves to a single message. `messages.list` returns the thread id in the
    /// listing itself, so this needs no follow-up fetch.
    private func findSentMessage(to recipient: String,
                                 around date: Date) async throws -> GmailAuthStore.SentMessage? {
        let after = Int(date.addingTimeInterval(-Self.recoveryWindow).timeIntervalSince1970)
        let before = Int(date.addingTimeInterval(Self.recoveryWindow).timeIntervalSince1970)
        let data = try await get("messages", [
            URLQueryItem(name: "q", value: "in:sent to:\(recipient) after:\(after) before:\(before)"),
            URLQueryItem(name: "maxResults", value: "2")
        ])
        struct Listing: Decodable { let messages: [GmailAuthStore.SentMessage]? }
        return try JSONDecoder().decode(Listing.self, from: data).messages?.first
    }

    // MARK: - Pass 2: look for an answer in each thread

    private struct Checked {
        var replies = 0
        var bounced = 0
        var failed = 0
        var bouncedRecruiters: Set<String> = []
    }

    private func checkForReplies(in sends: [MailSend]) async throws -> Checked {
        let cutoff = Date().addingTimeInterval(-Self.checkWindow)
        let targets = sends.filter {
            $0.gmailThreadID != nil && !$0.hasReplied && ($0.sentAt ?? .distantPast) > cutoff
        }
        guard !targets.isEmpty else { return Checked() }

        progress = Progress(label: "Checking for replies", done: 0, total: targets.count)
        var result = Checked()

        try await forEachChunk(targets) { send in
            guard let threadID = send.gmailThreadID else { return }
            do {
                switch try await self.firstResponse(inThread: threadID, after: send.sentAt) {
                case .reply(let date, let sender, let snippet):
                    try await SupabaseAPI.recordReply(sendID: send.id, at: date,
                                                      from: sender, snippet: snippet)
                    result.replies += 1
                case .bounce:
                    result.bounced += 1
                    result.bouncedRecruiters.insert(send.recruiterID)
                case .silent:
                    break
                }
            } catch let error as GmailAuthError where error.isScopeFailure {
                throw error
            } catch let error as SupabaseError where error.isSchemaOutOfDate {
                throw error
            } catch {
                result.failed += 1
            }
        }
        return result
    }

    private enum ThreadResponse {
        case reply(at: Date, from: String, snippet: String?)
        /// The only thing that came back was a delivery failure.
        case bounce
        case silent
    }

    /// Read one thread's headers and decide whether anybody answered.
    ///
    /// Three things in a thread are *not* an answer, and each is excluded on a
    /// different signal: our own messages (Gmail's `SENT` label), auto-replies
    /// (the `Auto-Submitted` / `Precedence` headers an out-of-office sets), and
    /// bounces (the mailer-daemon sender). Without those filters a fortnight
    /// away from the desk would read as a mailbox full of interested recruiters.
    private func firstResponse(inThread threadID: String, after sentAt: Date?) async throws -> ThreadResponse {
        // The id is interpolated into the request *path*, and `mail_sends` is
        // writable by anyone holding the app's anon key — so it is not
        // necessarily a value this app wrote. A `..` or a `?` in it would aim the
        // request at a different Gmail endpoint entirely. Gmail's ids are hex, so
        // anything else is rejected rather than sent.
        guard Self.isSafePathComponent(threadID) else { return .silent }

        let data = try await get("threads/\(threadID)", [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "Date"),
            URLQueryItem(name: "metadataHeaders", value: "Auto-Submitted"),
            URLQueryItem(name: "metadataHeaders", value: "Precedence")
        ])
        let thread = try JSONDecoder().decode(GmailThread.self, from: data)

        var sawBounce = false
        // Oldest first, so the first qualifying message is the first reply.
        for message in thread.messages.sorted(by: { $0.date < $1.date }) {
            guard !message.isOurs else { continue }
            if let sentAt, message.date <= sentAt { continue }
            if message.isBounce { sawBounce = true; continue }
            if message.isAutomated { continue }
            return .reply(at: message.date,
                          from: message.from ?? "",
                          snippet: message.snippet?.htmlUnescaped)
        }
        return sawBounce ? .bounce : .silent
    }

    // MARK: - Plumbing

    private func get(_ path: String, _ query: [URLQueryItem]) async throws -> Data {
        guard let reader else { throw GmailAuthError.notConnected }
        return try await reader(path, query)
    }

    /// Run `work` over every item, `concurrency` at a time, advancing `progress`.
    /// Bounded rather than unbounded so a few hundred sends don't open a few
    /// hundred sockets at once.
    private func forEachChunk(_ items: [MailSend],
                              _ work: @escaping (MailSend) async throws -> Void) async throws {
        for chunk in stride(from: 0, to: items.count, by: Self.concurrency).map({
            Array(items[$0..<min($0 + Self.concurrency, items.count)])
        }) {
            try Task.checkCancellation()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for item in chunk {
                    group.addTask { try await work(item) }
                }
                try await group.waitForAll()
            }
            progress.done += chunk.count
        }
    }
}

// MARK: - Gmail thread shapes

/// The slice of Gmail's thread resource this needs. Everything is optional:
/// these are other people's messages, and a header that "always" exists won't.
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

        /// Gmail stamps `internalDate` in milliseconds since the epoch. It's the
        /// server's own receive time, so unlike the `Date:` header it can't be
        /// backdated by the sender.
        var date: Date {
            guard let ms = internalDate.flatMap(Double.init) else { return .distantPast }
            return Date(timeIntervalSince1970: ms / 1000)
        }

        /// Our own copy of the mail (or a draft of one), never a response.
        var isOurs: Bool {
            let labels = labelIds ?? []
            return labels.contains("SENT") || labels.contains("DRAFT")
        }

        var from: String? { header("From") }

        /// Out-of-office and other machine-generated replies announce themselves
        /// in the headers; `vacation` is what Gmail's own responder sets.
        var isAutomated: Bool {
            if let auto = header("Auto-Submitted")?.lowercased(), auto != "no" { return true }
            if let precedence = header("Precedence")?.lowercased(),
               ["bulk", "auto_reply", "junk", "list"].contains(precedence) { return true }
            return (from ?? "").localizedCaseInsensitiveContains("no-reply")
                || (from ?? "").localizedCaseInsensitiveContains("noreply")
        }

        /// A delivery failure — the address is dead, which is the opposite of a
        /// reply and a strong hint the contact should be marked invalid.
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
    /// Whether this failure means "the token can't read mail", which the UI
    /// answers with a reconnect prompt rather than an error.
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
