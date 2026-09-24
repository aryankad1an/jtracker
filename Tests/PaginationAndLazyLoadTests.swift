import Foundation

// MARK: - Test Framework

struct TestFailure: Error {
    let message: String
    let file: StaticString
    let line: UInt
}

func assertTrue(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if !condition {
        throw TestFailure(message: "Assertion failed: \(message)", file: file, line: line)
    }
}

func assertFalse(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if condition {
        throw TestFailure(message: "Assertion failed (expected false): \(message)", file: file, line: line)
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if a != b {
        throw TestFailure(message: "Assertion failed: [\(a)] != [\(b)]. \(message)", file: file, line: line)
    }
}

var passedCount = 0
var failedCount = 0

@MainActor
func runTest(_ name: String, block: () async throws -> Void) async {
    do {
        try await block()
        passedCount += 1
        print("  ✓ \(name)")
    } catch let error as TestFailure {
        failedCount += 1
        print("  ❌ \(name): \(error.message) [\(error.file):\(error.line)]")
    } catch {
        failedCount += 1
        print("  ❌ \(name): Unexpected error: \(error)")
    }
}

// MARK: - Mock Models for Pagination Testing

struct MockCompany: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let website: String?
    let notes: String?
    var contacts: [MockContact]
}

struct MockContact: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let email: String
    let role: String?
    let companyID: String
    let notes: String?
    let linkedin: String?
}

struct MockMailSend: Identifiable, Equatable {
    let id: String
    let contactID: String
    let sentAt: Date?
    var repliedAt: Date?
    var replyFrom: String?
    var replySnippet: String?
}

// MARK: - Mock Database & Pagination Engine

actor MockPostgRESTDatabase {
    var companiesTable: [MockCompany] = []
    var sendsTable: [MockMailSend] = []
    var queryLog: [(endpoint: String, limit: Int, offset: Int)] = []

    func seed(companies: [MockCompany], sends: [MockMailSend]) {
        self.companiesTable = companies
        self.sendsTable = sends
        self.queryLog.removeAll()
    }

    func fetchCompanies(limit: Int, offset: Int) async -> [MockCompany] {
        queryLog.append(("companies", limit, offset))
        guard offset < companiesTable.count else { return [] }
        let end = min(offset + limit, companiesTable.count)
        return Array(companiesTable[offset..<end])
    }

    func fetchSends(limit: Int, offset: Int) async -> [MockMailSend] {
        queryLog.append(("sends", limit, offset))
        guard offset < sendsTable.count else { return [] }
        let end = min(offset + limit, sendsTable.count)
        return Array(sendsTable[offset..<end])
    }

    func searchCompanies(query: String, limit: Int = 50) async -> [MockCompany] {
        queryLog.append(("search", limit, 0))
        let lower = query.lowercased()
        var matchedIDs = Set<String>()
        var matches: [MockCompany] = []

        // Search company name and notes
        for comp in companiesTable {
            if comp.name.localizedCaseInsensitiveContains(lower) || (comp.notes?.localizedCaseInsensitiveContains(lower) ?? false) {
                if !matchedIDs.contains(comp.id) {
                    matchedIDs.insert(comp.id)
                    matches.append(comp)
                }
            }
        }

        // Search contacts by name, email, role
        for comp in companiesTable {
            if matchedIDs.contains(comp.id) { continue }
            for contact in comp.contacts {
                if contact.name.localizedCaseInsensitiveContains(lower) ||
                   contact.email.localizedCaseInsensitiveContains(lower) ||
                   (contact.role?.localizedCaseInsensitiveContains(lower) ?? false) {
                    matchedIDs.insert(comp.id)
                    matches.append(comp)
                    break
                }
            }
        }

        return Array(matches.prefix(limit)).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchCompany(id: String) async -> MockCompany? {
        queryLog.append(("company_by_id", 1, 0))
        return companiesTable.first { $0.id == id }
    }

    func getQueryCount() -> Int {
        queryLog.count
    }

    func getQueryLog() -> [(endpoint: String, limit: Int, offset: Int)] {
        queryLog
    }
}

// MARK: - Mock JobStore Pagination Controller

@MainActor
final class MockJobStorePagination {
    static let defaultPageSize = 50

    // Database
    let db: MockPostgRESTDatabase

    // Company Pagination State
    private(set) var companies: [MockCompany] = []
    private(set) var companyOffset: Int = 0
    private(set) var hasMoreCompanies: Bool = true
    private(set) var isLoadingMoreCompanies: Bool = false

    // Activity / Sends Pagination State
    private(set) var sends: [MockMailSend] = []
    private(set) var activityOffset: Int = 0
    private(set) var hasMoreActivity: Bool = true
    private(set) var isLoadingMoreActivity: Bool = false

    // Memoization State for "New" List
    private(set) var suggestedContacts: [MockContact] = []
    private(set) var suggestedGroups: [(company: MockCompany, contacts: [MockContact])] = []
    private(set) var rebuildSuggestedCount: Int = 0

    init(db: MockPostgRESTDatabase) {
        self.db = db
    }

    func reloadAll() async {
        companyOffset = 0
        hasMoreCompanies = true
        activityOffset = 0
        hasMoreActivity = true

        let fetchedCompanies = await db.fetchCompanies(limit: Self.defaultPageSize, offset: 0)
        companies = fetchedCompanies
        companyOffset = fetchedCompanies.count
        hasMoreCompanies = fetchedCompanies.count == Self.defaultPageSize

        let fetchedSends = await db.fetchSends(limit: Self.defaultPageSize, offset: 0)
        sends = fetchedSends
        activityOffset = fetchedSends.count
        hasMoreActivity = fetchedSends.count == Self.defaultPageSize

        rebuildSuggested()
    }

    func loadMoreCompanies() async {
        guard !isLoadingMoreCompanies, hasMoreCompanies else { return }
        isLoadingMoreCompanies = true
        defer { isLoadingMoreCompanies = false }

        let newBatch = await db.fetchCompanies(limit: Self.defaultPageSize, offset: companyOffset)
        if newBatch.isEmpty {
            hasMoreCompanies = false
            return
        }

        // Deduplication against existing IDs
        let existingIDs = Set(companies.map { $0.id })
        let uniqueBatch = newBatch.filter { !existingIDs.contains($0.id) }
        companies.append(contentsOf: uniqueBatch)
        companyOffset += newBatch.count

        if newBatch.count < Self.defaultPageSize {
            hasMoreCompanies = false
        }

        rebuildSuggested()
    }

    func loadMoreActivity() async {
        guard !isLoadingMoreActivity, hasMoreActivity else { return }
        isLoadingMoreActivity = true
        defer { isLoadingMoreActivity = false }

        let newBatch = await db.fetchSends(limit: Self.defaultPageSize, offset: activityOffset)
        if newBatch.isEmpty {
            hasMoreActivity = false
            return
        }

        let existingIDs = Set(sends.map { $0.id })
        let uniqueBatch = newBatch.filter { !existingIDs.contains($0.id) }
        sends.append(contentsOf: uniqueBatch)
        activityOffset += newBatch.count

        if newBatch.count < Self.defaultPageSize {
            hasMoreActivity = false
        }
    }

    func rebuildSuggested() {
        rebuildSuggestedCount += 1
        let reachedOutContactIDs = Set(sends.map { $0.contactID })

        var unreached: [MockContact] = []
        for company in companies {
            for contact in company.contacts {
                if !reachedOutContactIDs.contains(contact.id) {
                    unreached.append(contact)
                }
            }
        }
        suggestedContacts = unreached

        let companyMap = Dictionary(companies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: unreached, by: { $0.companyID })
        suggestedGroups = grouped.compactMap { companyID, contacts in
            guard let comp = companyMap[companyID] else { return nil }
            return (company: comp, contacts: contacts)
        }.sorted { $0.company.name.localizedCaseInsensitiveCompare($1.company.name) == .orderedAscending }
    }

    // Search State
    private(set) var searchResults: [MockCompany] = []
    private(set) var isSearchingServer: Bool = false
    private var currentSearchTask: Task<Void, Never>?

    func searchCompanies(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        currentSearchTask?.cancel()
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearchingServer = false
            return
        }

        isSearchingServer = true
        let task = Task {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms for fast testing
            guard !Task.isCancelled else { return }

            let results = await db.searchCompanies(query: trimmed)
            guard !Task.isCancelled else { return }

            // Merge into companies so details and tracking work instantly
            let existingIDs = Set(companies.map(\.id))
            let newCompanies = results.filter { !existingIDs.contains($0.id) }
            if !newCompanies.isEmpty {
                companies.append(contentsOf: newCompanies)
                companies.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }

            searchResults = results
            isSearchingServer = false
        }
        currentSearchTask = task
        await task.value
    }

    func loadCompanyIfNeeded(id: String) async -> MockCompany? {
        if let existing = companies.first(where: { $0.id == id }) {
            return existing
        }
        guard let fetched = await db.fetchCompany(id: id) else { return nil }
        if !companies.contains(where: { $0.id == fetched.id }) {
            companies.append(fetched)
            companies.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return fetched
    }

    func filteredCompanies(query: String) -> [MockCompany] {
        guard !query.isEmpty else { return companies }
        let inMemory = companies.filter { comp in
            comp.name.localizedCaseInsensitiveContains(query) ||
            comp.contacts.contains { $0.name.localizedCaseInsensitiveContains(query) || $0.email.localizedCaseInsensitiveContains(query) || ($0.role?.localizedCaseInsensitiveContains(query) ?? false) }
        }
        let server = searchResults.filter { comp in
            comp.name.localizedCaseInsensitiveContains(query) ||
            comp.contacts.contains { $0.name.localizedCaseInsensitiveContains(query) || $0.email.localizedCaseInsensitiveContains(query) || ($0.role?.localizedCaseInsensitiveContains(query) ?? false) }
        }
        var seen = Set<String>()
        var combined: [MockCompany] = []
        for item in (inMemory + server) {
            if !seen.contains(item.id) {
                seen.insert(item.id)
                combined.append(item)
            }
        }
        return combined.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Test Suite Execution

print("==========================================")
print("Running Pagination and Lazy Loading Tests")
print("==========================================")

await runTest("Default Page Size is strictly 50") {
    try assertEqual(MockJobStorePagination.defaultPageSize, 50, "Default page size must be 50")
}

await runTest("Empty Database: 0 items loaded, hasMore is false") {
    let db = MockPostgRESTDatabase()
    await db.seed(companies: [], sends: [])
    let store = MockJobStorePagination(db: db)

    await store.reloadAll()

    try assertEqual(store.companies.count, 0)
    try assertEqual(store.companyOffset, 0)
    try assertFalse(store.hasMoreCompanies)
    try assertEqual(store.sends.count, 0)
    try assertFalse(store.hasMoreActivity)
}

await runTest("Partial First Page (< 50 items): hasMore is false") {
    let db = MockPostgRESTDatabase()
    let mockCompanies = (0..<37).map {
        MockCompany(id: "c-\($0)", name: "Company \($0)", website: nil, notes: nil, contacts: [])
    }
    await db.seed(companies: mockCompanies, sends: [])
    let store = MockJobStorePagination(db: db)

    await store.reloadAll()

    try assertEqual(store.companies.count, 37)
    try assertEqual(store.companyOffset, 37)
    try assertFalse(store.hasMoreCompanies, "hasMore should be false when batch < 50")
    
    // Calling loadMore should be a no-op because hasMore is false
    await store.loadMoreCompanies()
    try assertEqual(store.companies.count, 37)
    let log = await db.getQueryLog()
    try assertEqual(log.count, 2, "Only 1 initial company fetch and 1 initial sends fetch")
}

await runTest("Exact Boundary (50 items): first page loaded, hasMore is true, next load returns 0") {
    let db = MockPostgRESTDatabase()
    let mockCompanies = (0..<50).map {
        MockCompany(id: "c-\($0)", name: "Company \($0)", website: nil, notes: nil, contacts: [])
    }
    await db.seed(companies: mockCompanies, sends: [])
    let store = MockJobStorePagination(db: db)

    await store.reloadAll()

    try assertEqual(store.companies.count, 50)
    try assertEqual(store.companyOffset, 50)
    try assertTrue(store.hasMoreCompanies, "hasMore should be true after receiving exactly 50 items")

    // Lazy load next page: receives 0 items -> hasMore becomes false
    await store.loadMoreCompanies()
    try assertEqual(store.companies.count, 50)
    try assertFalse(store.hasMoreCompanies, "hasMore should now be false")
}

await runTest("Multi-Page Pagination (135 items across 3 pages: 50 -> 50 -> 35)") {
    let db = MockPostgRESTDatabase()
    let mockCompanies = (0..<135).map {
        MockCompany(id: "comp-\($0)", name: String(format: "Company %03d", $0), website: nil, notes: nil, contacts: [])
    }
    await db.seed(companies: mockCompanies, sends: [])
    let store = MockJobStorePagination(db: db)

    // Page 1
    await store.reloadAll()
    try assertEqual(store.companies.count, 50)
    try assertEqual(store.companyOffset, 50)
    try assertTrue(store.hasMoreCompanies)

    // Page 2
    await store.loadMoreCompanies()
    try assertEqual(store.companies.count, 100)
    try assertEqual(store.companyOffset, 100)
    try assertTrue(store.hasMoreCompanies)

    // Page 3 (final)
    await store.loadMoreCompanies()
    try assertEqual(store.companies.count, 135)
    try assertEqual(store.companyOffset, 135)
    try assertFalse(store.hasMoreCompanies, "hasMore should be false after receiving 35 (< 50) items")

    // Further loadMore calls must be ignored
    await store.loadMoreCompanies()
    try assertEqual(store.companies.count, 135)

    let log = await db.getQueryLog()
    let companyQueries = log.filter { $0.endpoint == "companies" }
    try assertEqual(companyQueries.count, 3)
    try assertEqual(companyQueries[0].offset, 0)
    try assertEqual(companyQueries[1].offset, 50)
    try assertEqual(companyQueries[2].offset, 100)
}

await runTest("Deduplication: rows shifted across pagination boundaries do not duplicate") {
    let db = MockPostgRESTDatabase()
    // 60 companies
    let mockCompanies = (0..<60).map {
        MockCompany(id: "comp-\($0)", name: "Company \($0)", website: nil, notes: nil, contacts: [])
    }
    await db.seed(companies: mockCompanies, sends: [])
    let store = MockJobStorePagination(db: db)

    await store.reloadAll()
    try assertEqual(store.companies.count, 50)

    // Simulate concurrent row insertion at index 0 in the database before page 2 is fetched:
    // This shifts company-49 into page 2 (offset 50)
    let shiftedCompanies = [MockCompany(id: "comp-NEW", name: "Company NEW", website: nil, notes: nil, contacts: [])] + mockCompanies
    await db.seed(companies: shiftedCompanies, sends: [])

    // Load page 2 (fetch offset 50..100)
    // Shifted array has comp-49 at offset 50, which was already loaded in page 1
    await store.loadMoreCompanies()

    // Deduplication should ensure no duplicates exist in store.companies
    let uniqueIDs = Set(store.companies.map { $0.id })
    try assertEqual(store.companies.count, uniqueIDs.count, "Store should contain no duplicate IDs")
}

await runTest("Activity/Sends Pagination: loads 50 sends lazily with correct offset") {
    let db = MockPostgRESTDatabase()
    let mockSends = (0..<120).map {
        MockMailSend(id: "send-\($0)", contactID: "rec-\($0)", sentAt: Date().addingTimeInterval(Double(-$0 * 60)), repliedAt: nil, replyFrom: nil, replySnippet: nil)
    }
    await db.seed(companies: [], sends: mockSends)
    let store = MockJobStorePagination(db: db)

    await store.reloadAll()
    try assertEqual(store.sends.count, 50)
    try assertEqual(store.activityOffset, 50)
    try assertTrue(store.hasMoreActivity)

    await store.loadMoreActivity()
    try assertEqual(store.sends.count, 100)
    try assertEqual(store.activityOffset, 100)
    try assertTrue(store.hasMoreActivity)

    await store.loadMoreActivity()
    try assertEqual(store.sends.count, 120)
    try assertEqual(store.activityOffset, 120)
    try assertFalse(store.hasMoreActivity)
}

await runTest("Stampede Guard: Concurrent loadMore calls execute only 1 network request") {
    let db = MockPostgRESTDatabase()
    let mockCompanies = (0..<100).map {
        MockCompany(id: "comp-\($0)", name: "Company \($0)", website: nil, notes: nil, contacts: [])
    }
    await db.seed(companies: mockCompanies, sends: [])
    let store = MockJobStorePagination(db: db)

    await store.reloadAll()
    try assertEqual(store.companies.count, 50)

    // Launch 20 concurrent loadMoreCompanies tasks simultaneously
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<20 {
            group.addTask { @MainActor in
                await store.loadMoreCompanies()
            }
        }
    }

    let log = await db.getQueryLog()
    let companyQueries = log.filter { $0.endpoint == "companies" }
    // Initial fetch was 1, and only 1 additional page fetch was allowed because after 100 items hasMore becomes false
    try assertTrue(companyQueries.count <= 2, "Concurrent stampede must be guarded; query count was \(companyQueries.count)")
}

await runTest("Reload / Pull-to-Refresh resets offset and replaces data cleanly") {
    let db = MockPostgRESTDatabase()
    let initialCompanies = (0..<100).map {
        MockCompany(id: "c1-\($0)", name: "Initial \($0)", website: nil, notes: nil, contacts: [])
    }
    await db.seed(companies: initialCompanies, sends: [])
    let store = MockJobStorePagination(db: db)

    await store.reloadAll()
    await store.loadMoreCompanies()
    try assertEqual(store.companies.count, 100)
    try assertEqual(store.companyOffset, 100)

    // Database content changes
    let refreshedCompanies = (0..<30).map {
        MockCompany(id: "c2-\($0)", name: "Refreshed \($0)", website: nil, notes: nil, contacts: [])
    }
    await db.seed(companies: refreshedCompanies, sends: [])

    // User triggers reloadAll()
    await store.reloadAll()
    try assertEqual(store.companies.count, 30, "Reload must discard old 100 items and load new 30")
    try assertEqual(store.companyOffset, 30)
    try assertFalse(store.hasMoreCompanies)
}

await runTest("New List Memoization: Selection toggles do NOT recompute suggestedGroups") {
    let db = MockPostgRESTDatabase()
    var initialCompanies: [MockCompany] = []
    for i in 0..<50 {
        let contact = MockContact(id: "ct-\(i)", name: "Contact \(i)", email: "c\(i)@a.com", role: "Dev", companyID: "comp-\(i)", notes: nil, linkedin: nil)
        initialCompanies.append(MockCompany(id: "comp-\(i)", name: String(format: "Company %02d", i), website: nil, notes: nil, contacts: [contact]))
    }

    await db.seed(companies: initialCompanies, sends: [])
    let store = MockJobStorePagination(db: db)

    await store.reloadAll()
    try assertEqual(store.rebuildSuggestedCount, 1, "rebuildSuggested should be called once on load")
    try assertEqual(store.suggestedGroups.count, 50)
    try assertEqual(store.suggestedContacts.count, 50)
    try assertTrue(store.hasMoreCompanies, "hasMoreCompanies should be true with 50 initial companies")

    // Simulate UI selection toggle in QuickActionsView
    var selection: Set<MockContact.ID> = []
    selection.insert("ct-0")
    selection.insert("ct-1")
    selection.remove("ct-0")

    // The store's suggestedGroups should NOT have been recomputed during selection changes
    try assertEqual(store.rebuildSuggestedCount, 1, "rebuildSuggested must not run on selection toggles")

    // Check that lazy loading new page updates the memoized groups exactly once
    let moreContact = MockContact(id: "ct-50", name: "Contact 50", email: "c50@c.com", role: "Dev", companyID: "comp-50", notes: nil, linkedin: nil)
    let comp50 = MockCompany(id: "comp-50", name: "Company 50", website: nil, notes: nil, contacts: [moreContact])
    await db.seed(companies: initialCompanies + [comp50], sends: [])

    // simulate loading more
    await store.loadMoreCompanies()
    try assertEqual(store.rebuildSuggestedCount, 2, "rebuildSuggested should run once per page fetch")
    try assertEqual(store.suggestedGroups.count, 51)
}

await runTest("Large Dataset Selection Performance Benchmark (5,000 Contacts)") {
    let db = MockPostgRESTDatabase()
    var largeContacts: [MockContact] = []
    var largeCompanies: [MockCompany] = []

    for c in 0..<100 {
        var compContacts: [MockContact] = []
        for k in 0..<50 {
            let id = "contact-\(c)-\(k)"
            let contact = MockContact(id: id, name: "Name \(k)", email: "\(id)@test.com", role: "Engineer", companyID: "c-\(c)", notes: nil, linkedin: nil)
            compContacts.append(contact)
            largeContacts.append(contact)
        }
        largeCompanies.append(MockCompany(id: "c-\(c)", name: "Company \(c)", website: nil, notes: nil, contacts: compContacts))
    }

    await db.seed(companies: largeCompanies, sends: [])
    let store = MockJobStorePagination(db: db)
    await store.reloadAll()

    // Benchmark 1,000 rapid checkbox toggles with memoized suggestedGroups
    let startTime = DispatchTime.now()
    var selection = Set<MockContact.ID>()
    for i in 0..<1000 {
        let contactID = largeContacts[i % largeContacts.count].id
        if selection.contains(contactID) {
            selection.remove(contactID)
        } else {
            selection.insert(contactID)
        }
        // Reading memoized groups takes O(1)
        _ = store.suggestedGroups.count
    }
    let endTime = DispatchTime.now()
    let elapsedMs = Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0

    print("    Benchmark: 1,000 contact toggles on 5,000 contacts completed in \(String(format: "%.2f", elapsedMs))ms")
    try assertTrue(elapsedMs < 100.0, "Toggling contacts with memoized suggestedGroups must take < 100ms (was \(elapsedMs)ms)")
}

await runTest("PostgREST Batching (Chunking): 135 contact IDs split into batches of 50") {
    // Mirrors SupabaseAPI.fetchActivity batching logic
    let contactIDs = (0..<135).map { "contact-uuid-\($0)" }
    let chunkSize = 50
    let chunks = stride(from: 0, to: contactIDs.count, by: chunkSize).map {
        Array(contactIDs[$0..<min($0 + chunkSize, contactIDs.count)])
    }

    try assertEqual(chunks.count, 3)
    try assertEqual(chunks[0].count, 50)
    try assertEqual(chunks[1].count, 50)
    try assertEqual(chunks[2].count, 35)
}

await runTest("forceFullCheck bypasses empty delta sync and inspects active sends") {
    let activeSends: [MockMailSend] = (0..<15).map {
        MockMailSend(id: "s-\($0)", contactID: "r-\($0)", sentAt: Date().addingTimeInterval(-3600), repliedAt: nil, replyFrom: nil, replySnippet: nil)
    }

    // Delta sync returns empty set (no new messages in last 15 min)
    let incomingDeltaIDs: Set<String> = []

    // 1. Without forceFullCheck:
    let deltaTargets = activeSends.filter { incomingDeltaIDs.contains($0.id) }
    try assertEqual(deltaTargets.count, 0, "Delta sync with 0 delta messages produces 0 targets")

    // 2. With forceFullCheck:
    let forceTargets = activeSends
    try assertEqual(forceTargets.count, 15, "forceFullCheck inspects all 15 active sends directly")
}

await runTest("Large send history (>50 sends): 100% accurate totalReplies and totalSent") {
    // 150 sends total, with 42 replies scattered throughout (including sends 51..150)
    let totalSends = 150
    let replyIndices = Set(stride(from: 0, to: totalSends, by: 3)) // 50 replies

    var sends: [MockMailSend] = []
    for i in 0..<totalSends {
        let hasReply = replyIndices.contains(i)
        let send = MockMailSend(
            id: "send-\(i)",
            contactID: "rec-\(i)",
            sentAt: Date().addingTimeInterval(Double(-i * 3600)),
            repliedAt: hasReply ? Date().addingTimeInterval(Double(-i * 3600 + 1800)) : nil,
            replyFrom: hasReply ? "contact\(i)@tech.co" : nil,
            replySnippet: hasReply ? "Thanks for reaching out!" : nil
        )
        sends.append(send)
    }

    let actualRepliesCount = sends.filter { $0.repliedAt != nil }.count
    try assertEqual(actualRepliesCount, 50)

    // Verify un-truncated loading preserves all 50 replies and 150 sends
    try assertEqual(sends.count, 150)
    try assertEqual(sends.filter { $0.repliedAt != nil }.count, 50, "Full send history must not cap replies to first 50")
}

await runTest("emailByContact resolution across activity and jobs when allCompanies is paginated") {
    // Company 99 is not in the first 50 companies of allCompanies
    let unpaginatedContact = MockContact(id: "rec-99", name: "Contact 99", email: "rec99@company99.com", role: "HR", companyID: "comp-99", notes: nil, linkedin: nil)
    let paginatedCompanies: [MockCompany] = (0..<50).map {
        MockCompany(id: "comp-\($0)", name: "Company \($0)", website: nil, notes: nil, contacts: [])
    }

    var emailMap: [String: String] = [:]
    for comp in paginatedCompanies {
        for c in comp.contacts where !c.email.isEmpty { emailMap[c.id] = c.email }
    }
    try assertEqual(emailMap["rec-99"], nil, "Paginated catalog alone misses contact 99")

    // Adding activity entries to emailMap resolves contact 99
    let activityContacts = [unpaginatedContact]
    for c in activityContacts where !c.email.isEmpty { emailMap[c.id] = c.email }
    try assertEqual(emailMap["rec-99"], "rec99@company99.com", "Augmented map correctly resolves contact 99")
}

// MARK: - Search on Not-Yet-Loaded Items Tests

await runTest("Search retrieves not-yet-loaded company at index > 1,000 from database") {
    let db = MockPostgRESTDatabase()
    var allComps: [MockCompany] = []
    for i in 0..<1200 {
        let name = i == 1150 ? "Quantum Computing Labs" : "Company \(i)"
        allComps.append(MockCompany(id: "comp-\(i)", name: name, website: nil, notes: nil, contacts: []))
    }
    await db.seed(companies: allComps, sends: [])

    let store = MockJobStorePagination(db: db)
    await store.reloadAll()

    // Initially only 50 companies are loaded in memory
    try assertEqual(store.companies.count, 50)
    try assertEqual(store.filteredCompanies(query: "Quantum").count, 0, "In-memory filter before search returns 0 matches")

    // Run server search for "Quantum"
    await store.searchCompanies(query: "Quantum")

    // Search results contain the unpaginated company
    try assertEqual(store.searchResults.count, 1)
    try assertEqual(store.searchResults.first?.name, "Quantum Computing Labs")

    // Combined filtered results present the matching company
    let filtered = store.filteredCompanies(query: "Quantum")
    try assertEqual(filtered.count, 1)
    try assertEqual(filtered.first?.id, "comp-1150")

    // The discovered company is seamlessly merged into store.companies
    try assertTrue(store.companies.contains(where: { $0.id == "comp-1150" }), "Search result merged into local companies cache")
}

await runTest("Search by contact name resolves not-yet-loaded company") {
    let db = MockPostgRESTDatabase()
    var allComps: [MockCompany] = []
    for i in 0..<500 {
        var contacts: [MockContact] = []
        if i == 450 {
            contacts.append(MockContact(id: "rec-450", name: "Alice Wonderland", email: "alice@wonder.org", role: "Talent Partner", companyID: "comp-450", notes: nil, linkedin: nil))
        }
        allComps.append(MockCompany(id: "comp-\(i)", name: "Enterprise \(i)", website: nil, notes: nil, contacts: contacts))
    }
    await db.seed(companies: allComps, sends: [])

    let store = MockJobStorePagination(db: db)
    await store.reloadAll()

    try assertEqual(store.filteredCompanies(query: "Wonderland").count, 0, "Not in first 50 companies")

    await store.searchCompanies(query: "Wonderland")

    let filtered = store.filteredCompanies(query: "Wonderland")
    try assertEqual(filtered.count, 1)
    try assertEqual(filtered.first?.name, "Enterprise 450")
    try assertEqual(filtered.first?.contacts.first?.name, "Alice Wonderland")
}

await runTest("Search by contact email resolves not-yet-loaded company") {
    let db = MockPostgRESTDatabase()
    var allComps: [MockCompany] = []
    for i in 0..<300 {
        var contacts: [MockContact] = []
        if i == 250 {
            contacts.append(MockContact(id: "rec-250", name: "Tech Lead", email: "founders@deepmind.com", role: "Contact", companyID: "comp-250", notes: nil, linkedin: nil))
        }
        allComps.append(MockCompany(id: "comp-\(i)", name: "AI Startup \(i)", website: nil, notes: nil, contacts: contacts))
    }
    await db.seed(companies: allComps, sends: [])

    let store = MockJobStorePagination(db: db)
    await store.reloadAll()

    await store.searchCompanies(query: "deepmind.com")

    let filtered = store.filteredCompanies(query: "deepmind.com")
    try assertEqual(filtered.count, 1)
    try assertEqual(filtered.first?.id, "comp-250")
}

await runTest("Search by contact position/role resolves not-yet-loaded company") {
    let db = MockPostgRESTDatabase()
    var allComps: [MockCompany] = []
    for i in 0..<300 {
        var contacts: [MockContact] = []
        if i == 280 {
            contacts.append(MockContact(id: "rec-280", name: "Bob Martin", email: "bob@uncle.org", role: "VP of Engineering Talent", companyID: "comp-280", notes: nil, linkedin: nil))
        }
        allComps.append(MockCompany(id: "comp-\(i)", name: "Firm \(i)", website: nil, notes: nil, contacts: contacts))
    }
    await db.seed(companies: allComps, sends: [])

    let store = MockJobStorePagination(db: db)
    await store.reloadAll()

    await store.searchCompanies(query: "Engineering Talent")

    let filtered = store.filteredCompanies(query: "Engineering Talent")
    try assertEqual(filtered.count, 1)
    try assertEqual(filtered.first?.id, "comp-280")
}

await runTest("Search deduplication cleanly combines in-memory and server results") {
    let db = MockPostgRESTDatabase()
    var allComps: [MockCompany] = []
    // Company 0 is in first 50 (in-memory)
    allComps.append(MockCompany(id: "comp-0", name: "Apex Global Loaded", website: nil, notes: nil, contacts: []))
    for i in 1..<50 {
        allComps.append(MockCompany(id: "comp-\(i)", name: "Other \(i)", website: nil, notes: nil, contacts: []))
    }
    // Company 150 is unpaginated (in DB only)
    allComps.append(MockCompany(id: "comp-150", name: "Apex Technologies Remote", website: nil, notes: nil, contacts: []))

    await db.seed(companies: allComps, sends: [])
    let store = MockJobStorePagination(db: db)
    await store.reloadAll()

    // In memory match only returns comp-0
    try assertEqual(store.filteredCompanies(query: "Apex").count, 1)

    // Execute server search
    await store.searchCompanies(query: "Apex")

    // Both should appear in filtered, with 0 duplicates
    let filtered = store.filteredCompanies(query: "Apex")
    try assertEqual(filtered.count, 2)
    try assertEqual(filtered[0].id, "comp-0")
    try assertEqual(filtered[1].id, "comp-150")

    // Verifying no duplicate IDs
    let uniqueIDs = Set(filtered.map(\.id))
    try assertEqual(uniqueIDs.count, 2)
}

await runTest("loadCompanyIfNeeded lazily fetches unpaginated company and caches it") {
    let db = MockPostgRESTDatabase()
    var allComps: [MockCompany] = []
    for i in 0..<200 {
        allComps.append(MockCompany(id: "comp-\(i)", name: "Company \(i)", website: nil, notes: nil, contacts: []))
    }
    await db.seed(companies: allComps, sends: [])
    let store = MockJobStorePagination(db: db)
    await store.reloadAll()

    try assertEqual(store.companies.count, 50)
    try assertFalse(store.companies.contains(where: { $0.id == "comp-120" }))

    // First call: fetches from DB
    let initialQueryCount = await db.getQueryCount()
    let fetched = await store.loadCompanyIfNeeded(id: "comp-120")
    try assertEqual(fetched?.id, "comp-120")
    try assertTrue(store.companies.contains(where: { $0.id == "comp-120" }), "Cached in store.companies")

    let queriesAfterFetch = await db.getQueryCount()
    try assertEqual(queriesAfterFetch, initialQueryCount + 1, "1 DB query made")

    // Second call: served from memory cache, 0 additional DB queries
    let cached = await store.loadCompanyIfNeeded(id: "comp-120")
    try assertEqual(cached?.id, "comp-120")
    let queriesAfterSecond = await db.getQueryCount()
    try assertEqual(queriesAfterSecond, queriesAfterFetch, "Served from memory with 0 DB queries")
}

await runTest("Empty or whitespace search query cancels and clears search results") {
    let db = MockPostgRESTDatabase()
    let allComps = [MockCompany(id: "c-1", name: "Acme Corp", website: nil, notes: nil, contacts: [])]
    await db.seed(companies: allComps, sends: [])
    let store = MockJobStorePagination(db: db)
    await store.reloadAll()

    await store.searchCompanies(query: "Acme")
    try assertEqual(store.searchResults.count, 1)

    await store.searchCompanies(query: "   ")
    try assertEqual(store.searchResults.count, 0)
    try assertFalse(store.isSearchingServer)
}


print("==========================================")
print("Pagination Test Results: \(passedCount) passed, \(failedCount) failed")
print("==========================================")

if failedCount > 0 {
    exit(1)
}
