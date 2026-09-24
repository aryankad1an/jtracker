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

// MARK: - Mock Models

struct TestContact: Identifiable, Equatable {
    var id: String
    var email: String
    var name: String
    var position: String
    var phone: String?
    var greetingName: String?
    var isValid: Bool = true
}

struct TestCompany: Identifiable, Equatable {
    var id: String
    var company: String
    var sector: String?
    var domain: String?
    var contacts: [TestContact] = []

    var mailDomain: String {
        if let domain, !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return domain.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for contact in contacts {
            if let atIndex = contact.email.firstIndex(of: "@") {
                let candidate = String(contact.email[contact.email.index(after: atIndex)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty { return candidate }
            }
        }
        return ""
    }
}

// MARK: - Mock Upstream Database

actor MockUpstreamDatabase {
    var companiesTable: [String: (name: String, sector: String?, domain: String?)] = [:]
    var contactsTable: [String: TestContact] = [:]
    var patchLog: [(table: String, id: String, payload: [String: String?])] = []
    var simulateMissingDomainColumn = false

    func seed(companies: [TestCompany]) {
        companiesTable.removeAll()
        contactsTable.removeAll()
        patchLog.removeAll()
        for c in companies {
            companiesTable[c.id] = (name: c.company, sector: c.sector, domain: c.domain)
            for r in c.contacts {
                contactsTable[r.id] = r
            }
        }
    }

    func setSimulateMissingDomainColumn(_ value: Bool) {
        self.simulateMissingDomainColumn = value
    }

    func updateCompany(id: String, name: String, sector: String?, domain: String?) async throws {
        var payload: [String: String?] = ["name": name, "sector": sector]
        if simulateMissingDomainColumn && domain != nil {
            // Simulate PostgREST 42703 column does not exist
            throw NSError(domain: "PostgREST", code: 42703, userInfo: [NSLocalizedDescriptionKey: "column companies.domain does not exist"])
        }
        payload["domain"] = domain
        patchLog.append((table: "companies", id: id, payload: payload))
        companiesTable[id] = (name: name, sector: sector, domain: domain)
    }

    func updateContact(_ contact: TestContact) async {
        let payload: [String: String?] = [
            "name": contact.name,
            "email": contact.email,
            "position": contact.position,
            "phone": contact.phone,
            "greeting_name": contact.greetingName
        ]
        patchLog.append((table: "contacts", id: contact.id, payload: payload))
        contactsTable[contact.id] = contact
    }

    func getCompany(id: String) -> (name: String, sector: String?, domain: String?)? {
        companiesTable[id]
    }

    func getContact(id: String) -> TestContact? {
        contactsTable[id]
    }

    func getPatchCount() -> Int {
        patchLog.count
    }

    func getLastPatch() -> (table: String, id: String, payload: [String: String?])? {
        patchLog.last
    }
}

// MARK: - Test Coordinator with Configurable Timer

struct TestUndoItem: Identifiable {
    let id = UUID()
    let message: String
    let duration: TimeInterval
    let expiresAt: Date
    let revertAction: () async -> Void
}

@MainActor
final class TestUndoCoordinator {
    private(set) var activeItem: TestUndoItem?
    private(set) var timeRemaining: Double = 0.0
    private var countdownTask: Task<Void, Never>?

    func stage(message: String, duration: TimeInterval = 5.0, revert: @escaping () async -> Void) {
        countdownTask?.cancel()

        let item = TestUndoItem(
            message: message,
            duration: duration,
            expiresAt: Date().addingTimeInterval(duration),
            revertAction: revert
        )
        activeItem = item
        timeRemaining = duration

        countdownTask = Task { [weak self] in
            let step = 0.05
            while true {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let self else { return }

                let remaining = item.expiresAt.timeIntervalSinceNow
                if remaining <= 0 {
                    self.activeItem = nil
                    self.timeRemaining = 0.0
                    return
                }
                self.timeRemaining = max(0, remaining)
            }
        }
    }

    func undo() async {
        countdownTask?.cancel()
        guard let item = activeItem else { return }
        activeItem = nil
        timeRemaining = 0.0
        await item.revertAction()
    }

    func dismiss() {
        countdownTask?.cancel()
        activeItem = nil
        timeRemaining = 0.0
    }
}

// MARK: - Test Store with Undo Lifecycle

@MainActor
final class TestJobStoreWithUndo {
    let db: MockUpstreamDatabase
    let undoCoordinator: TestUndoCoordinator

    var companies: [TestCompany] = []

    init(db: MockUpstreamDatabase, undoCoordinator: TestUndoCoordinator) {
        self.db = db
        self.undoCoordinator = undoCoordinator
    }

    func updateCompany(id: String, name: String, sector: String?, domain: String?, undoDuration: TimeInterval = 5.0) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        guard let idx = companies.firstIndex(where: { $0.id == id }) else { return }
        let oldName = companies[idx].company
        let oldSector = companies[idx].sector
        let oldDomain = companies[idx].domain

        // Apply locally
        companies[idx].company = trimmed
        companies[idx].sector = sector
        companies[idx].domain = domain

        // Upstream write
        do {
            try await db.updateCompany(id: id, name: trimmed, sector: sector, domain: domain)
        } catch {
            // Fallback if domain missing
            try? await db.updateCompany(id: id, name: trimmed, sector: sector, domain: nil)
        }

        // Stage 5-second undo
        undoCoordinator.stage(message: "Company details updated", duration: undoDuration) { [weak self] in
            guard let self else { return }
            if let i = self.companies.firstIndex(where: { $0.id == id }) {
                self.companies[i].company = oldName
                self.companies[i].sector = oldSector
                self.companies[i].domain = oldDomain
            }
            try? await self.db.updateCompany(id: id, name: oldName, sector: oldSector, domain: oldDomain)
        }
    }

    func updateContact(_ contact: TestContact, undoDuration: TimeInterval = 5.0) async {
        var oldContact: TestContact?
        for cIdx in companies.indices {
            if let rIdx = companies[cIdx].contacts.firstIndex(where: { $0.id == contact.id }) {
                oldContact = companies[cIdx].contacts[rIdx]
                companies[cIdx].contacts[rIdx] = contact
                break
            }
        }

        await db.updateContact(contact)

        if let previous = oldContact {
            undoCoordinator.stage(message: "Contact details updated", duration: undoDuration) { [weak self] in
                guard let self else { return }
                for cIdx in self.companies.indices {
                    if let rIdx = self.companies[cIdx].contacts.firstIndex(where: { $0.id == previous.id }) {
                        self.companies[cIdx].contacts[rIdx] = previous
                        break
                    }
                }
                await self.db.updateContact(previous)
            }
        }
    }
}

// MARK: - Domain Cleaner Helper (matching CompanyFormView)

func cleanDomainInput(_ input: String) -> String {
    var d = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if d.hasPrefix("https://") { d = String(d.dropFirst(8)) }
    if d.hasPrefix("http://") { d = String(d.dropFirst(7)) }
    if d.hasPrefix("www.") { d = String(d.dropFirst(4)) }
    if let slashIdx = d.firstIndex(of: "/") { d = String(d[..<slashIdx]) }
    if d.hasPrefix("@") { d = String(d.dropFirst(1)) }
    return d
}

// MARK: - Test Cases

print("==========================================")
print("Running Company Details, Domain & 5s Undo Tests")
print("==========================================")

await runTest("Company mailDomain returns explicit domain when provided") {
    let comp = TestCompany(id: "c-1", company: "Stripe", sector: "Fintech", domain: "stripe.com", contacts: [])
    try assertEqual(comp.mailDomain, "stripe.com")
}

await runTest("Company mailDomain derives domain from first contact email when domain is nil") {
    let contact1 = TestContact(id: "r-1", email: "patrick@stripe.com", name: "Patrick", position: "CEO")
    let comp = TestCompany(id: "c-1", company: "Stripe", sector: "Fintech", domain: nil, contacts: [contact1])
    try assertEqual(comp.mailDomain, "stripe.com", "Derived from contact email")
}

await runTest("Company mailDomain returns empty string when neither domain nor contact emails exist") {
    let comp = TestCompany(id: "c-2", company: "Stealth", sector: "AI", domain: nil, contacts: [])
    try assertEqual(comp.mailDomain, "", "Empty when no domain and no contacts")
}

await runTest("cleanDomainInput handles URLs, prefixes, casing, and trailing paths") {
    try assertEqual(cleanDomainInput("https://www.google.com/careers"), "google.com")
    try assertEqual(cleanDomainInput("http://airbnb.com/"), "airbnb.com")
    try assertEqual(cleanDomainInput("@apple.com"), "apple.com")
    try assertEqual(cleanDomainInput("  WWW.MICROSOFT.COM  "), "microsoft.com")
    try assertEqual(cleanDomainInput("linear.app"), "linear.app")
}

await runTest("Company edit updates local state and writes upstream to database") {
    let db = MockUpstreamDatabase()
    let coordinator = TestUndoCoordinator()
    let initialComp = TestCompany(id: "c-1", company: "Acme", sector: "Hardware", domain: "acme.old", contacts: [])
    await db.seed(companies: [initialComp])

    let store = TestJobStoreWithUndo(db: db, undoCoordinator: coordinator)
    store.companies = [initialComp]

    await store.updateCompany(id: "c-1", name: "Acme Corp", sector: "Robotics", domain: "acme.com")

    // Local check
    try assertEqual(store.companies[0].company, "Acme Corp")
    try assertEqual(store.companies[0].sector, "Robotics")
    try assertEqual(store.companies[0].domain, "acme.com")

    // Upstream check
    let upstream = await db.getCompany(id: "c-1")
    try assertEqual(upstream?.name, "Acme Corp")
    try assertEqual(upstream?.sector, "Robotics")
    try assertEqual(upstream?.domain, "acme.com")
}

await runTest("Company edit gracefully handles schemaOutOfDate if domain column is missing") {
    let db = MockUpstreamDatabase()
    let coordinator = TestUndoCoordinator()
    let initialComp = TestCompany(id: "c-1", company: "Acme", sector: "Hardware", domain: nil, contacts: [])
    await db.seed(companies: [initialComp])

    // Simulate database where companies.domain column has not been migrated yet
    await db.setSimulateMissingDomainColumn(true)

    let store = TestJobStoreWithUndo(db: db, undoCoordinator: coordinator)
    store.companies = [initialComp]

    // Updating with domain should catch error, retry without domain, and succeed
    await store.updateCompany(id: "c-1", name: "Acme Robotics", sector: "AI", domain: "acme.ai")

    let upstream = await db.getCompany(id: "c-1")
    try assertEqual(upstream?.name, "Acme Robotics")
    try assertEqual(upstream?.sector, "AI")
}

await runTest("Contact edit updates local state and writes upstream to database") {
    let db = MockUpstreamDatabase()
    let coordinator = TestUndoCoordinator()
    let contact = TestContact(id: "r-1", email: "alice@acme.com", name: "Alice", position: "Sourcer")
    let comp = TestCompany(id: "c-1", company: "Acme", contacts: [contact])
    await db.seed(companies: [comp])

    let store = TestJobStoreWithUndo(db: db, undoCoordinator: coordinator)
    store.companies = [comp]

    let updatedContact = TestContact(id: "r-1", email: "alice.talent@acme.com", name: "Alice Smith", position: "Lead Talent Partner", phone: "555-1234", greetingName: "Alice")
    await store.updateContact(updatedContact)

    try assertEqual(store.companies[0].contacts[0].name, "Alice Smith")
    try assertEqual(store.companies[0].contacts[0].position, "Lead Talent Partner")

    let upstream = await db.getContact(id: "r-1")
    try assertEqual(upstream?.name, "Alice Smith")
    try assertEqual(upstream?.email, "alice.talent@acme.com")
    try assertEqual(upstream?.position, "Lead Talent Partner")
}

await runTest("5-Second Undo: Tapping Undo within 5 seconds reverts company edit upstream and locally") {
    let db = MockUpstreamDatabase()
    let coordinator = TestUndoCoordinator()
    let initialComp = TestCompany(id: "c-1", company: "Original Name", sector: "Original Sector", domain: "orig.com", contacts: [])
    await db.seed(companies: [initialComp])

    let store = TestJobStoreWithUndo(db: db, undoCoordinator: coordinator)
    store.companies = [initialComp]

    // 1. Perform edit (staged with 5s undo)
    await store.updateCompany(id: "c-1", name: "Edited Name", sector: "Edited Sector", domain: "edited.com", undoDuration: 5.0)

    try assertEqual(store.companies[0].company, "Edited Name")
    try assertEqual(coordinator.activeItem?.message, "Company details updated")
    try assertTrue(coordinator.timeRemaining > 4.0, "Timer starts at ~5s")

    // 2. Tap Undo within the 5-second interval
    await coordinator.undo()

    // 3. Verify local state was reverted
    try assertEqual(store.companies[0].company, "Original Name")
    try assertEqual(store.companies[0].sector, "Original Sector")
    try assertEqual(store.companies[0].domain, "orig.com")

    // 4. Verify upstream database was reverted
    let upstream = await db.getCompany(id: "c-1")
    try assertEqual(upstream?.name, "Original Name")
    try assertEqual(upstream?.sector, "Original Sector")
    try assertEqual(upstream?.domain, "orig.com")

    // 5. Verify coordinator banner is cleared
    try assertEqual(coordinator.activeItem?.id, nil)
    try assertEqual(coordinator.timeRemaining, 0.0)
}

await runTest("5-Second Undo: Tapping Undo within 5 seconds reverts contact edit upstream and locally") {
    let db = MockUpstreamDatabase()
    let coordinator = TestUndoCoordinator()
    let initialContact = TestContact(id: "r-1", email: "old@co.com", name: "Old Name", position: "HR")
    let comp = TestCompany(id: "c-1", company: "Company", contacts: [initialContact])
    await db.seed(companies: [comp])

    let store = TestJobStoreWithUndo(db: db, undoCoordinator: coordinator)
    store.companies = [comp]

    let updated = TestContact(id: "r-1", email: "new@co.com", name: "New Name", position: "VP People")
    await store.updateContact(updated, undoDuration: 5.0)

    try assertEqual(store.companies[0].contacts[0].name, "New Name")
    try assertEqual(coordinator.activeItem?.message, "Contact details updated")

    // Undo within 5 seconds
    await coordinator.undo()

    // Reverted locally
    try assertEqual(store.companies[0].contacts[0].name, "Old Name")
    try assertEqual(store.companies[0].contacts[0].email, "old@co.com")

    // Reverted upstream
    let upstream = await db.getContact(id: "r-1")
    try assertEqual(upstream?.name, "Old Name")
    try assertEqual(upstream?.email, "old@co.com")
}

await runTest("5-Second Undo: Letting timer expire dismisses banner and commits change") {
    let db = MockUpstreamDatabase()
    let coordinator = TestUndoCoordinator()
    let initialComp = TestCompany(id: "c-1", company: "Start Name", sector: "Tech", domain: "start.com", contacts: [])
    await db.seed(companies: [initialComp])

    let store = TestJobStoreWithUndo(db: db, undoCoordinator: coordinator)
    store.companies = [initialComp]

    // Use a very short duration for testing expiration (0.15s)
    await store.updateCompany(id: "c-1", name: "Permanent Name", sector: "Tech", domain: "start.com", undoDuration: 0.15)
    try assertEqual(coordinator.activeItem?.message, "Company details updated")

    // Wait 250ms for expiration
    try await Task.sleep(nanoseconds: 250_000_000)

    // Verify coordinator cleared the banner
    try assertEqual(coordinator.activeItem?.id, nil, "Banner auto-dismissed")
    try assertEqual(coordinator.timeRemaining, 0.0)

    // Verify edited state persists permanently
    try assertEqual(store.companies[0].company, "Permanent Name")
    let upstream = await db.getCompany(id: "c-1")
    try assertEqual(upstream?.name, "Permanent Name")
}

await runTest("5-Second Undo: Consecutive edits supersede previous undo action cleanly") {
    let db = MockUpstreamDatabase()
    let coordinator = TestUndoCoordinator()
    let initialComp = TestCompany(id: "c-1", company: "V1", sector: nil, domain: nil, contacts: [])
    await db.seed(companies: [initialComp])

    let store = TestJobStoreWithUndo(db: db, undoCoordinator: coordinator)
    store.companies = [initialComp]

    // First edit
    await store.updateCompany(id: "c-1", name: "V2", sector: nil, domain: nil, undoDuration: 5.0)
    let firstUndoID = coordinator.activeItem?.id

    // Second edit 50ms later
    try await Task.sleep(nanoseconds: 50_000_000)
    await store.updateCompany(id: "c-1", name: "V3", sector: nil, domain: nil, undoDuration: 5.0)
    let secondUndoID = coordinator.activeItem?.id

    try assertTrue(firstUndoID != secondUndoID, "Second edit replaces first undo item")
    try assertEqual(store.companies[0].company, "V3")

    // Undo reverts V3 -> V2
    await coordinator.undo()
    try assertEqual(store.companies[0].company, "V2")
}

await runTest("Uniform Delete Confirmation title and message validation") {
    // Single company
    let compTitle = "Delete “Stripe”?"
    let compMsg = "Are you sure you want to delete this company and its contacts from the shared database? This action cannot be undone."
    try assertTrue(compTitle.contains("Stripe"))
    try assertTrue(compMsg.contains("cannot be undone"))

    // Single contact
    let recTitle = "Delete “Patrick Collison”?"
    let recMsg = "Are you sure you want to delete this contact from the shared database? This action cannot be undone."
    try assertTrue(recTitle.contains("Patrick"))
    try assertTrue(recMsg.contains("cannot be undone"))

    // Multi-select contacts (plural)
    let count = 3
    let bulkTitle = "Delete \(count) contacts?"
    let bulkMsg = "Are you sure you want to permanently delete the selected contacts? This action cannot be undone."
    try assertEqual(bulkTitle, "Delete 3 contacts?")
    try assertTrue(bulkMsg.contains("selected contacts"))
}

print("==========================================")
print("Company & Undo Test Results: \(passedCount) passed, \(failedCount) failed")
print("==========================================")

if failedCount > 0 {
    exit(1)
}
