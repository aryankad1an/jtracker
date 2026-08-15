import Foundation
import Observation

/// The app's data layer. Companies and recruiters are a shared catalog in
/// Supabase; each Gmail user tracks a subset of companies (by id) and has their
/// own per-user "sent" state, overlaid onto the catalog at load time. Every
/// mutation writes to the database and then reloads, so on-screen state always
/// mirrors what's stored.
@Observable
final class JobStore {
    /// The user's tracked companies, with recruiters and sent state.
    private(set) var jobs: [Job] = []
    /// The Activity feed: every recruiter the user has sent to, newest first.
    /// Loaded from the send history, so it's independent of which companies are
    /// currently tracked on Home.
    private(set) var activity: [ActivityEntry] = []
    /// The full catalog, for the "add company" picker.
    private(set) var catalog: [CatalogCompany] = []

    private(set) var isLoading = false
    private(set) var isCatalogLoading = false
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

    /// Catalog companies the user hasn't added to their home yet.
    var availableCompanies: [CatalogCompany] {
        let taken = Set(jobs.map(\.id))
        return catalog.filter { !taken.contains($0.id) }
    }

    // MARK: - Loading

    /// Load the user's tracked companies (with recruiters + sent state).
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            try await reloadJobs()
        } catch {
            report(error)
        }
        isLoading = false
    }

    /// Load the full catalog for the picker.
    func loadCatalog() async {
        isCatalogLoading = true
        defer { isCatalogLoading = false }
        do {
            catalog = try await SupabaseAPI.fetchCatalog()
        } catch {
            report(error)
        }
    }

    // MARK: - Company mutations (home selection syncs per account)

    /// Track an existing catalog company on this user's home. Optimistic: the row
    /// appears immediately from the catalog entry, then the server write and a
    /// quiet reload (to fill in the company's recruiters) run in the background.
    func addCatalogCompany(_ company: CatalogCompany) async {
        guard let email = userEmail else { return }
        guard !jobs.contains(where: { $0.id == company.id }) else { return }
        mutateTracked { if !$0.contains(company.id) { $0.append(company.id) } }
        insertSorted(Job(id: company.id, company: company.name))
        do {
            try await SupabaseAPI.addTracked(userEmail: email, companyID: company.id)
            try await reloadJobs()
        } catch {
            // Roll the optimistic row back if the server rejected the add.
            mutateTracked { $0.removeAll { $0 == company.id } }
            jobs.removeAll { $0.id == company.id }
            report(error)
        }
    }

    /// Create a new company in the shared catalog (server), then track it on this
    /// user's home. Both writes are server-side, so this keeps the saving overlay.
    func addCustomCompany(name: String, sector: String? = nil) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let email = userEmail else { return }
        await perform {
            let id = try await SupabaseAPI.addCompany(name: trimmed, sector: sector)
            try await SupabaseAPI.addTracked(userEmail: email, companyID: id)
            self.mutateTracked { if !$0.contains(id) { $0.append(id) } }
        }
        await loadCatalog()
    }

    /// Remove a company from this user's home. Instant: drops it from the list and
    /// cache right away, with the server untrack fired in the background. The
    /// shared catalog (and anyone else's home) is untouched.
    func deleteJob(_ job: Job) {
        guard let email = userEmail else { return }
        mutateTracked { $0.removeAll { $0 == job.id } }
        jobs.removeAll { $0.id == job.id }
        pushTracked(add: false, companyID: job.id, email: email)
    }

    /// Re-track a company that was just removed from Home — powers the Undo
    /// action. Reuses the removed `Job` we still have, so it's instant too.
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
    func markContactsSent(_ records: [Contact.ID: SentMail]) async {
        guard !records.isEmpty, let email = userEmail else { return }
        await perform {
            let now = Date()
            for (id, mail) in records {
                try await SupabaseAPI.recordSend(userEmail: email, recruiterID: id, mail: mail, at: now)
            }
        }
    }

    // MARK: - Helpers

    /// Fetch this user's tracked companies and overlay their sent records.
    private func reloadJobs() async throws {
        guard let email = userEmail else { jobs = []; activity = []; return }

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

        // Sends come newest-first, so the first row per recruiter is their latest.
        let sends = try await SupabaseAPI.fetchSends(userEmail: email)
        let byRecruiter = Dictionary(sends.map { ($0.recruiterID, $0) }, uniquingKeysWith: { latest, _ in latest })
        for j in companies.indices {
            for c in companies[j].contacts.indices {
                guard let send = byRecruiter[companies[j].contacts[c].id] else { continue }
                companies[j].contacts[c].isSent = true
                companies[j].contacts[c].sentAt = send.sentAt
                companies[j].contacts[c].sentSubject = send.subject
                companies[j].contacts[c].sentBody = send.body
            }
        }
        jobs = companies

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

    /// Run a write, then refresh from the database so local state stays in sync.
    /// `inFlight` drives the app-wide "Saving…" state for the whole round-trip.
    private func perform(_ operation: () async throws -> Void) async {
        inFlight += 1
        defer { inFlight -= 1 }
        do {
            try await operation()
            try await reloadJobs()
        } catch {
            report(error)
        }
    }

    /// Surface an error, ignoring cancellations from interrupted view reloads.
    private func report(_ error: Error) {
        if !error.isCancellation { errorMessage = error.localizedDescription }
    }
}
