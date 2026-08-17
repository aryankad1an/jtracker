import Foundation
import Observation

/// The app's data layer. Companies and recruiters are a shared catalog in
/// Supabase; each Gmail user tracks a subset of companies (by id) and has their
/// own per-user "sent" state, overlaid onto the catalog at load time. Every
/// mutation writes to the database and then reloads, so on-screen state always
/// mirrors what's stored.
@Observable
final class JobStore {
    /// The user's tracked companies, with recruiters and sent state. Drives Home's
    /// "Tracking" section.
    private(set) var jobs: [Job] = []
    /// Every company in the shared catalog, with recruiters and this user's sent
    /// state overlaid. Drives the Companies list and Home's cross-company
    /// "Suggested" section.
    private(set) var allCompanies: [Job] = []
    /// The Activity feed: every recruiter the user has sent to, newest first.
    /// Loaded from the send history, so it's independent of which companies are
    /// currently tracked on Home.
    private(set) var activity: [ActivityEntry] = []

    private(set) var isLoading = false
    var errorMessage: String?

    /// The connected Gmail address whose data we show. Set on sign-in.
    var userEmail: String?

    private var inFlight = 0
    /// True while a write and its confirming reload are in progress.
    var isSaving: Bool { inFlight > 0 }

    // MARK: - Home selection (synced per account)

    /// Which companies are on Home now lives server-side in `tracked_companies`,
    /// keyed by account email, so a user's selection follows them across devices.
    /// This on-device copy is a cache: it lets Home render its membership instantly
    /// and survive an offline launch, but the server is the source of truth and
    /// overwrites it on every successful load.
    private let trackedFile = JSONFile<[String: [String]]>(name: "home_companies.json")
    private var trackedByEmail: [String: [String]]

    init() {
        trackedByEmail = trackedFile.load() ?? [:]
    }

    /// Mutate and persist the current user's cached tracked ids (local only — the
    /// matching server write is fired separately by the caller).
    private func mutateTracked(_ transform: (inout [String]) -> Void) {
        guard let email = userEmail else { return }
        var ids = trackedByEmail[email] ?? []
        transform(&ids)
        trackedByEmail[email] = ids
        trackedFile.save(trackedByEmail)
    }

    /// Push a membership change to the server in the background so the UI never
    /// waits on the network. Best-effort: a failed push is surfaced, and the next
    /// full load reconciles against the server either way.
    private func pushTracked(add: Bool, companyID: String, email: String) {
        Task {
            do {
                if add {
                    try await SupabaseAPI.addTracked(userEmail: email, companyID: companyID)
                } else {
                    try await SupabaseAPI.removeTracked(userEmail: email, companyID: companyID)
                }
            } catch {
                report(error)
            }
        }
    }

    /// Whether this account's pre-sync, on-device selection has been lifted up to
    /// the server yet. Tracked in UserDefaults so it runs exactly once per account.
    private func hasMigrated(_ email: String) -> Bool {
        UserDefaults.standard.bool(forKey: "home.synced.\(email)")
    }

    private func markMigrated(_ email: String) {
        UserDefaults.standard.set(true, forKey: "home.synced.\(email)")
    }

    func clearError() { errorMessage = nil }

    // MARK: - Lookups

    /// A company by id, from the full catalog first (most complete) and then the
    /// tracked list — so a detail screen works whether or not it's tracked.
    func company(id: String) -> Job? {
        allCompanies.first { $0.id == id } ?? jobs.first { $0.id == id }
    }

    /// Whether the company is on this user's Home.
    func isTracked(_ id: String) -> Bool {
        jobs.contains { $0.id == id }
    }

    /// Contacts across every company that can be cold-mailed (valid email) and
    /// haven't been mailed in the last month — never-sent first, then oldest sent.
    /// Powers Home's "Suggested" section.
    var suggestedContacts: [(company: Job, contact: Contact)] {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        var result: [(company: Job, contact: Contact)] = []
        for company in allCompanies {
            for contact in company.contacts where contact.email.contains("@") {
                if !contact.isSent || (contact.sentAt ?? .distantPast) < cutoff {
                    result.append((company, contact))
                }
            }
        }
        return result.sorted { a, b in
            switch (a.contact.sentAt, b.contact.sentAt) {
            case (nil, nil):
                return a.company.company.localizedCaseInsensitiveCompare(b.company.company) == .orderedAscending
            case (nil, _?): return true
            case (_?, nil): return false
            case let (l?, r?): return l < r
            }
        }
    }

    /// `suggestedContacts` grouped by company, preserving the flat list's urgency
    /// order (a company appears at the position of its most-overdue contact).
    var suggestedGroups: [(company: Job, contacts: [Contact])] {
        var order: [String] = []
        var byID: [String: (company: Job, contacts: [Contact])] = [:]
        for item in suggestedContacts {
            if byID[item.company.id] == nil {
                byID[item.company.id] = (item.company, [])
                order.append(item.company.id)
            }
            byID[item.company.id]?.contacts.append(item.contact)
        }
        return order.compactMap { byID[$0] }
    }

    // MARK: - Loading

    /// Load the user's tracked companies and the full catalog (both with recruiters
    /// + sent state), plus the Activity feed.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            try await reloadAll()
        } catch {
            report(error)
        }
        isLoading = false
    }

    // MARK: - Tracking (home selection, syncs per account)

    /// Track a company on this user's Home. Optimistic: it appears in the tracked
    /// list immediately (reusing the full catalog row we already have), with the
    /// server write fired in the background.
    func track(companyID: String) {
        guard let email = userEmail else { return }
        guard !jobs.contains(where: { $0.id == companyID }) else { return }
        mutateTracked { if !$0.contains(companyID) { $0.append(companyID) } }
        if let company = allCompanies.first(where: { $0.id == companyID }) {
            insertSorted(company)
        }
        pushTracked(add: true, companyID: companyID, email: email)
    }

    /// Untrack a company from this user's Home. Instant + background push; the
    /// shared catalog (and anyone else's Home) is untouched.
    func untrack(companyID: String) {
        guard let email = userEmail else { return }
        mutateTracked { $0.removeAll { $0 == companyID } }
        jobs.removeAll { $0.id == companyID }
        pushTracked(add: false, companyID: companyID, email: email)
    }

    /// Track several companies at once (Companies multi-select).
    func trackCompanies(_ ids: [String]) {
        for id in ids { track(companyID: id) }
    }

    /// Untrack via a `Job` — powers Home's swipe-to-remove.
    func deleteJob(_ job: Job) { untrack(companyID: job.id) }

    /// Re-track a company that was just removed from Home — powers the Undo action.
    func restoreJob(_ job: Job) {
        guard let email = userEmail else { return }
        mutateTracked { if !$0.contains(job.id) { $0.append(job.id) } }
        pushTracked(add: true, companyID: job.id, email: email)
        insertSorted(job)
    }

    /// Insert a job keeping the alphabetical order Home displays.
    private func insertSorted(_ job: Job) {
        guard !jobs.contains(where: { $0.id == job.id }) else { return }
        jobs.append(job)
        jobs.sort { $0.company.localizedCaseInsensitiveCompare($1.company) == .orderedAscending }
    }

    // MARK: - Catalog mutations (shared, upstream — change the DB for everyone)

    /// Create a new company in the shared catalog. Not auto-tracked; it appears in
    /// the Companies list (with "Show empty" on) ready for contacts.
    func createCompany(name: String, sector: String? = nil) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        await perform {
            _ = try await SupabaseAPI.addCompany(name: trimmed, sector: sector)
        }
    }

    /// Rename or re-sector a catalog company (upstream, for everyone).
    func updateCompany(id: String, name: String, sector: String?) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        await perform {
            try await SupabaseAPI.updateCompany(id: id, name: trimmed, sector: sector)
        }
    }

    /// Delete a company from the shared catalog (upstream). The reload afterwards
    /// reconciles the tracked cache against server truth, so it drops off Home too.
    func deleteCompanyUpstream(_ id: String) async {
        await perform {
            try await SupabaseAPI.deleteCompany(id: id)
        }
    }

    // MARK: - Cold mail mutations

    func addContact(_ contact: Contact, to job: Job) async {
        await perform { try await SupabaseAPI.addRecruiter(companyID: job.id, contact: contact) }
    }

    func updateContact(_ contact: Contact) async {
        await perform { try await SupabaseAPI.updateRecruiter(contact) }
    }

    /// Delete a cold mail. Sent mails are kept as a record and can't be removed.
    func deleteContact(_ contact: Contact) async {
        guard !contact.isSent else { return }
        await perform { try await SupabaseAPI.deleteRecruiter(id: contact.id) }
    }

    /// Append a send to this user's history for each recruiter. Does nothing
    /// when no Gmail is connected — you can't send without it.
    ///
    /// Deliberately not routed through `perform`: this is called by `MailQueue`
    /// when a background run finishes, which can be minutes after the user left
    /// the send screen. Raising the app-wide "Saving…" block there would freeze
    /// whatever they'd moved on to, for a write they didn't ask for and aren't
    /// waiting on — the exact thing sending in the background is meant to avoid.
    /// The reload still happens, so the UI catches up; it just does it quietly.
    func markContactsSent(_ records: [Contact.ID: SentMail]) async {
        guard !records.isEmpty, let email = userEmail else { return }
        do {
            let now = Date()
            for (id, mail) in records {
                try await SupabaseAPI.recordSend(userEmail: email, recruiterID: id, mail: mail, at: now)
            }
            try await reloadAll()
        } catch {
            report(error)
        }
    }

    // MARK: - Helpers

    /// Fetch this user's tracked companies and the full catalog, overlay their
    /// sent records, and rebuild the Activity feed.
    private func reloadAll() async throws {
        guard let email = userEmail else { jobs = []; allCompanies = []; activity = []; return }

        // One-time per account: lift any pre-sync, on-device selection up to the
        // server so it isn't lost now that the server owns Home membership.
        if !hasMigrated(email) {
            let serverIDs = Set(try await SupabaseAPI.fetchTrackedIDs(userEmail: email))
            for id in (trackedByEmail[email] ?? []) where !serverIDs.contains(id) {
                try await SupabaseAPI.addTracked(userEmail: email, companyID: id)
            }
            markMigrated(email)
        }

        // Server is the source of truth for membership; mirror it into the cache.
        var companies = try await SupabaseAPI.fetchTrackedCompanies(userEmail: email)
        trackedByEmail[email] = companies.map(\.id)
        trackedFile.save(trackedByEmail)

        var all = try await SupabaseAPI.fetchAllCompanies()

        // Sends come newest-first, so the first row per recruiter is their latest.
        // Overlay the same per-user sent state onto both the tracked list and the
        // full catalog.
        let sends = try await SupabaseAPI.fetchSends(userEmail: email)
        let byRecruiter = Dictionary(sends.map { ($0.recruiterID, $0) }, uniquingKeysWith: { latest, _ in latest })
        overlaySends(byRecruiter, into: &companies)
        overlaySends(byRecruiter, into: &all)
        jobs = companies
        allCompanies = all

        // Activity is built from the full send history (not the tracked list), so
        // removing a company from Home leaves its sent records here untouched, and
        // every send — including repeats to the same recruiter — is its own row.
        activity = try await SupabaseAPI.fetchActivity(sends: sends)
            .sorted { a, b in
                switch (a.date, b.date) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.company.localizedCaseInsensitiveCompare(b.company) == .orderedAscending
                }
            }
    }

    /// Overlay this user's per-recruiter sent state onto a set of companies.
    private func overlaySends(_ byRecruiter: [String: MailSend], into companies: inout [Job]) {
        for j in companies.indices {
            for c in companies[j].contacts.indices {
                guard let send = byRecruiter[companies[j].contacts[c].id] else { continue }
                companies[j].contacts[c].isSent = true
                companies[j].contacts[c].sentAt = send.sentAt
                companies[j].contacts[c].sentSubject = send.subject
                companies[j].contacts[c].sentBody = send.body
            }
        }
    }

    /// Run a write, then refresh from the database so local state stays in sync.
    /// `inFlight` drives the app-wide "Saving…" state for the whole round-trip.
    private func perform(_ operation: () async throws -> Void) async {
        inFlight += 1
        defer { inFlight -= 1 }
        do {
            try await operation()
            try await reloadAll()
        } catch {
            report(error)
        }
    }

    /// Surface an error, ignoring cancellations from interrupted view reloads.
    private func report(_ error: Error) {
        if !error.isCancellation { errorMessage = error.localizedDescription }
    }
}
