import Foundation

/// Everything the Insights screen shows, computed once per load rather than
/// re-derived inside a view body.
///
/// It's built from the Activity feed (one entry per *send*) instead of from the
/// company catalog, for the same reason Activity is: outreach history has to
/// survive a company being untracked or a contact being marked invalid. The
/// catalog is consulted only to resolve a company name back to something
/// navigable.
struct Insights {

    /// One company's outreach record. `id` is the company name, which is what the
    /// send history actually preserves — `companyID` is nil when the company has
    /// since left the catalog.
    struct CompanyStat: Identifiable {
        let name: String
        let companyID: String?
        /// Every send to this company, newest first.
        let entries: [ActivityEntry]
        let lastSentAt: Date?
        let lastReplyAt: Date?
        let sent: Int
        let replies: Int
        let people: Int

        var id: String { name }
        var isSilent: Bool { replies == 0 }

        init(name: String, companyID: String?, entries: [ActivityEntry]) {
            self.name = name
            self.companyID = companyID
            self.entries = entries
            self.lastSentAt = entries.compactMap(\.date).max()
            self.lastReplyAt = entries.compactMap(\.contact.repliedAt).max()
            self.sent = entries.count
            self.replies = entries.count { $0.contact.hasReplied }
            self.people = Set(entries.map(\.contact.id)).count
        }

        /// Whole days since the last mail went out. The number the "waiting on"
        /// list is ordered by, and the one worth acting on: a company silent for
        /// three weeks is a different problem from one mailed yesterday.
        var daysWaiting: Int? {
            guard let lastSentAt else { return nil }
            return Calendar.current.dateComponents([.day], from: lastSentAt, to: .now).day
        }
    }

    var companies: [CompanyStat] = []

    /// Companies that have heard from you and said nothing back, longest silence
    /// first — the running order of the follow-up queue.
    var waitingOn: [CompanyStat] = []
    /// Companies where somebody replied, most recent first.
    var responded: [CompanyStat] = []

    var totalSent = 0
    var totalReplies = 0
    /// Distinct people who wrote back — replies counts sends, and the same person
    /// answering twice isn't two leads.
    var repliedPeople = 0
    /// Sends still unanswered, newest first.
    var unanswered: [ActivityEntry] = []
    /// Everyone who wrote back, most recent reply first.
    var replies: [ActivityEntry] = []

    var replyRate: Double {
        totalSent == 0 ? 0 : Double(totalReplies) / Double(totalSent)
    }

    /// Typical wait before an answer arrives, in days — the median rather than the
    /// mean, so one recruiter who answered six weeks later doesn't move it.
    var medianResponseDays: Int?

    /// The longest anyone has been left hanging, in days.
    var longestSilenceDays: Int? { waitingOn.first?.daysWaiting }

    // MARK: - Building

    static func make(activity: [ActivityEntry], catalog: [Job]) -> Insights {
        var insights = Insights()
        insights.totalSent = activity.count
        insights.replies = activity
            .filter(\.contact.hasReplied)
            .sorted { ($0.contact.repliedAt ?? .distantPast) > ($1.contact.repliedAt ?? .distantPast) }
        insights.totalReplies = insights.replies.count
        insights.repliedPeople = Set(insights.replies.map(\.contact.id)).count
        insights.unanswered = activity.filter { !$0.contact.hasReplied }

        let idByName = Dictionary(catalog.map { ($0.company, $0.id) }, uniquingKeysWith: { first, _ in first })

        // Preserve the feed's newest-first order within each company, and order
        // the companies themselves by however the caller sorts them later.
        var order: [String] = []
        var byCompany: [String: [ActivityEntry]] = [:]
        for entry in activity where !entry.company.isEmpty {
            if byCompany[entry.company] == nil { order.append(entry.company) }
            byCompany[entry.company, default: []].append(entry)
        }

        insights.companies = order.map { name in
            CompanyStat(name: name, companyID: idByName[name], entries: byCompany[name] ?? [])
        }

        // The lanes are derived once here rather than on each access: a view body
        // reads several of them, and SwiftUI re-reads them on every pass.
        insights.waitingOn = insights.companies
            .filter(\.isSilent)
            .sorted { ($0.lastSentAt ?? .distantPast) < ($1.lastSentAt ?? .distantPast) }
        insights.responded = insights.companies
            .filter { !$0.isSilent }
            .sorted { ($0.lastReplyAt ?? .distantPast) > ($1.lastReplyAt ?? .distantPast) }

        let waits = insights.replies.compactMap { entry -> Int? in
            guard let sent = entry.date, let replied = entry.contact.repliedAt else { return nil }
            return Calendar.current.dateComponents([.day], from: sent, to: replied).day
        }.sorted()
        insights.medianResponseDays = waits.isEmpty ? nil : waits[waits.count / 2]

        return insights
    }
}
