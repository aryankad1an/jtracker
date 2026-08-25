import Foundation
import Observation
import UIKit

/// Sends cold mails in the background, one at a time, spaced out.
///
/// Sending used to happen inside the send sheet: you tapped Send All and then sat
/// on a progress bar until the last mail went out, unable to use the app, and a
/// hundred near-identical mails left in a tight loop. This moves the work behind
/// the UI — the sheet closes the moment you confirm, and the queue drains at a
/// deliberate pace while you carry on.
///
/// The pacing is the point, not a side effect. A burst of identical mail from a
/// consumer Gmail account is the clearest spam signature there is, and the damage
/// lands on the sender's own domain reputation — every *future* mail, not just
/// this batch.
///
/// The queue holds no references to the auth or data stores; `sender` and
/// `onCompletion` are supplied by `RootView`, which owns both.
enum MailQueueError: LocalizedError {
    case noTransport

    var errorDescription: String? { "No mail account is connected." }
}

@Observable
@MainActor
final class MailQueue {

    /// One mail, already rendered — the queue never re-renders from a template,
    /// so what was reviewed on screen is exactly what goes out.
    struct Mail: Identifiable {
        let id: Contact.ID
        let recipient: String
        let displayName: String
        let subject: String
        let body: String
    }

    struct Outcome {
        let sent: Int
        let failed: [String]
    }

    /// What the transport reports back about a delivered mail. The thread id is
    /// how a reply is recognised later, so it's carried from the send all the way
    /// into the stored record rather than looked up afterwards.
    struct Delivery {
        let messageID: String
        let threadID: String
    }

    /// Gap between sends. Fast enough to clear a large batch in a couple of
    /// minutes, slow enough not to look automated: Gmail's API allows roughly two
    /// sends a second, but the limit that matters is the spam heuristic, not the
    /// quota.
    private static let spacing = Duration.milliseconds(1200)
    /// Random slack either side of `spacing`, so the send pattern isn't perfectly
    /// periodic the way only a machine's would be.
    private static let jitter = 400

    private(set) var total = 0
    private(set) var sent = 0
    private(set) var failed: [String] = []
    private(set) var isRunning = false

    /// Set when a run finishes so the UI can report it. Cleared by `acknowledge()`.
    private(set) var outcome: Outcome?

    /// Delivers one mail and reports what the provider called it. Injected so the
    /// queue stays independent of Gmail auth.
    var sender: ((Mail, String) async throws -> Delivery?)?
    /// Called once per run with everything that got through, so the store can
    /// record the sends in a single write rather than one per mail.
    var onCompletion: (([Contact.ID: SentMail]) async -> Void)?

    private var pending: [Mail] = []
    private var task: Task<Void, Never>?
    private var fromName = ""

    /// True whenever there's something for the UI to show — mid-run, or a result
    /// the user hasn't acknowledged yet.
    var isActive: Bool { isRunning || outcome != nil }

    var completed: Int { sent + failed.count }

    var progress: Double {
        total == 0 ? 0 : Double(completed) / Double(total)
    }

    // MARK: - Queueing

    /// Add mails to the queue, starting a run if one isn't already going.
    ///
    /// Mails queued while a run is in flight join that run rather than starting a
    /// competing one — two loops sending at once would defeat the spacing.
    func enqueue(_ mails: [Mail], fromName: String) {
        guard !mails.isEmpty else { return }
        self.fromName = fromName

        if isRunning {
            pending.append(contentsOf: mails)
            total += mails.count
            return
        }

        pending = mails
        total = mails.count
        sent = 0
        failed = []
        outcome = nil
        start()
    }

    /// Stop after the in-flight mail. Anything already sent stays sent.
    func cancel() {
        task?.cancel()
        task = nil
        pending = []
    }

    /// Dismiss a finished run's result.
    func acknowledge() {
        outcome = nil
        total = 0
        sent = 0
        failed = []
    }

    // MARK: - Draining

    private func start() {
        isRunning = true
        task = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        let assertion = beginAssertion()
        defer { endAssertion(assertion) }

        var records: [Contact.ID: SentMail] = [:]

        while !pending.isEmpty && !Task.isCancelled {
            let mail = pending.removeFirst()
            do {
                // No transport means nothing was delivered. Recording these as
                // sent would mark a whole batch of recruiters as mailed without a
                // single mail leaving the account.
                guard let sender else { throw MailQueueError.noTransport }
                let delivery = try await sender(mail, fromName)
                records[mail.id] = SentMail(subject: mail.subject, body: mail.body,
                                            gmailMessageID: delivery?.messageID,
                                            gmailThreadID: delivery?.threadID)
                sent += 1
            } catch {
                failed.append(mail.displayName)
            }

            if !pending.isEmpty && !Task.isCancelled {
                try? await Task.sleep(for: Self.spacing + .milliseconds(Int.random(in: -Self.jitter...Self.jitter)))
            }
        }

        // Record even a cancelled run's successes — those mails really were sent,
        // and losing them would offer to re-send people who've already been mailed.
        if !records.isEmpty {
            await onCompletion?(records)
        }

        isRunning = false
        task = nil
        outcome = Outcome(sent: records.count, failed: failed)
    }

    // MARK: - Background execution

    /// Ask for a few extra seconds if the app is backgrounded mid-run. This isn't
    /// a guarantee of finishing: once iOS suspends the app the loop simply stops
    /// awaiting and picks up again on return, which is why the UI tells the user
    /// the queue continues when they come back rather than promising delivery.
    private func beginAssertion() -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: "MailQueue") { }
    }

    private func endAssertion(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}
