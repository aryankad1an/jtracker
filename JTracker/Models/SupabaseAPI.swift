import Foundation

/// Talks to Supabase's auto-generated REST API (PostgREST). Companies and
/// recruiters are a shared catalog; each user's Home selection is stored on-device
/// (client-side), while sent records (`mail_sends`) stay server-side.
enum SupabaseAPI {
    // MARK: - Catalog (every company, with recruiters)

    /// Every company in the shared catalog, each with its recruiters and sector.
    /// A left join, so companies with no recruiters are included too — the
    /// Companies list decides whether to show them. Sorted by name.
    static func fetchAllCompanies() async throws -> [Job] {
        let request = makeRequest(path: "companies", query: [
            URLQueryItem(name: "select", value: "id,name,sector,recruiters(id,name,email,position,phone)"),
            URLQueryItem(name: "order", value: "name")
        ])
        let data = try await send(request)
        return try decoder.decode([Job].self, from: data)
    }

    // MARK: - Home selection (tracked companies, per user)

    /// This user's tracked companies (with recruiters), resolved in one request:
    /// PostgREST embeds the `companies` row (and its `recruiters`) for each
    /// `tracked_companies` membership row, so the whole Home payload comes back in
    /// a single round trip. Sorted by name here since the join order isn't stable.
    static func fetchTrackedCompanies(userEmail: String) async throws -> [Job] {
        let request = makeRequest(path: "tracked_companies", query: [
            URLQueryItem(name: "select", value: "companies(id,name,recruiters(id,name,email,position,phone))"),
            URLQueryItem(name: "user_email", value: "eq.\(userEmail)")
        ])
        let data = try await send(request)
        // Each row wraps the embedded company; a company deleted out from under a
        // membership row (before the FK cascade fires) comes back null — skip it.
        struct Row: Decodable { let companies: Job? }
        return try decoder.decode([Row].self, from: data)
            .compactMap(\.companies)
            .sorted { $0.company.localizedCaseInsensitiveCompare($1.company) == .orderedAscending }
    }

    /// Just the tracked company ids for this user. Used once per account to lift a
    /// pre-sync, on-device selection up to the server (see `JobStore`).
    static func fetchTrackedIDs(userEmail: String) async throws -> [String] {
        let request = makeRequest(path: "tracked_companies", query: [
            URLQueryItem(name: "select", value: "company_id"),
            URLQueryItem(name: "user_email", value: "eq.\(userEmail)")
        ])
        let data = try await send(request)
        struct Row: Decodable { let company_id: String }
        return try decoder.decode([Row].self, from: data).map(\.company_id)
    }

    /// Track a company on this user's Home. Idempotent: upserts on the composite
    /// primary key so re-adding an already-tracked company is a no-op.
    static func addTracked(userEmail: String, companyID: String) async throws {
        let body: [String: Any] = ["user_email": userEmail, "company_id": companyID]
        try await write(method: "POST", path: "tracked_companies", body: body,
                        prefer: "return=minimal,resolution=merge-duplicates",
                        onConflict: "user_email,company_id")
    }

    /// Untrack a company from this user's Home.
    static func removeTracked(userEmail: String, companyID: String) async throws {
        try await write(method: "DELETE", path: "tracked_companies", query: [
            URLQueryItem(name: "user_email", value: "eq.\(userEmail)"),
            URLQueryItem(name: "company_id", value: "eq.\(companyID)")
        ])
    }

    /// Every send this user has made, newest first. One row per send, so the
    /// same recruiter can appear multiple times (the send history).
    static func fetchSends(userEmail: String) async throws -> [MailSend] {
        let request = makeRequest(path: "mail_sends", query: [
            URLQueryItem(name: "select", value: "id,recruiter_id,sent_at,subject,body"),
            URLQueryItem(name: "user_email", value: "eq.\(userEmail)"),
            URLQueryItem(name: "order", value: "sent_at.desc")
        ])
        let data = try await send(request)
        return try decoder.decode([MailSend].self, from: data)
    }

    /// The full send history for one recruiter, newest first.
    static func fetchSendHistory(userEmail: String, recruiterID: String) async throws -> [MailSend] {
        let request = makeRequest(path: "mail_sends", query: [
            URLQueryItem(name: "select", value: "id,recruiter_id,sent_at,subject,body"),
            URLQueryItem(name: "user_email", value: "eq.\(userEmail)"),
            URLQueryItem(name: "recruiter_id", value: "eq.\(recruiterID)"),
            URLQueryItem(name: "order", value: "sent_at.desc")
        ])
        let data = try await send(request)
        return try decoder.decode([MailSend].self, from: data)
    }

    /// Build the Activity feed from the user's full send history — one entry per
    /// send, so re-sending the same recruiter shows up as a separate row. Each
    /// recruiter's name/position and company are resolved (even for companies the
    /// user no longer tracks, so history survives a Home removal). `sends` is the
    /// raw list from `fetchSends`, newest first.
    static func fetchActivity(sends: [MailSend]) async throws -> [ActivityEntry] {
        guard !sends.isEmpty else { return [] }
        let ids = Array(Set(sends.map(\.recruiterID)))
        let request = makeRequest(path: "recruiters", query: [
            URLQueryItem(name: "select", value: "id,name,email,position,companies(name)"),
            URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))")
        ])
        let data = try await send(request)
        struct Row: Decodable {
            let id: String
            let name: String?
            let email: String?
            let position: String?
            struct Company: Decodable { let name: String }
            let companies: Company?
        }
        let rows = try decoder.decode([Row].self, from: data)
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // One entry per send, keyed by the send's own id (unique per send).
        return sends.compactMap { send -> ActivityEntry? in
            guard let row = byID[send.recruiterID] else { return nil }
            let contact = Contact(id: row.id, email: row.email ?? "", name: row.name ?? "",
                                  position: row.position ?? "", isSent: true, sentAt: send.sentAt,
                                  sentSubject: send.subject, sentBody: send.body)
            return ActivityEntry(id: send.id, company: row.companies?.name ?? "", contact: contact)
        }
    }

    // MARK: - Company catalog writes

    /// Create a company in the catalog and return its new id.
    static func addCompany(name: String, sector: String?) async throws -> String {
        var body: [String: Any] = ["name": name]
        if let sector, !sector.isEmpty { body["sector"] = sector }
        return try await insertReturningID(path: "companies", body: body)
    }

    /// Rename or re-sector a catalog company. Empty sector clears the column.
    static func updateCompany(id: String, name: String, sector: String?) async throws {
        let body: [String: Any] = [
            "name": name,
            "sector": (sector?.isEmpty ?? true) ? NSNull() : sector!
        ]
        try await write(method: "PATCH", path: "companies",
                        query: [URLQueryItem(name: "id", value: "eq.\(id)")],
                        body: body)
    }

    /// Delete a company from the shared catalog. The database cascades this to the
    /// company's recruiters and every user's tracked/sent rows for it.
    static func deleteCompany(id: String) async throws {
        try await write(method: "DELETE", path: "companies",
                        query: [URLQueryItem(name: "id", value: "eq.\(id)")])
    }

    // MARK: - Cold mail (recruiter) writes

    /// Add a recruiter (upserting on (company_id, email) so it's identified by
    /// email within a company) and return its id, so the caller can record a send.
    @discardableResult
    static func addRecruiter(companyID: String, contact: Contact) async throws -> String {
        var body = recruiterBody(contact)
        body["company_id"] = companyID
        return try await insertReturningID(path: "recruiters", body: body,
                                           onConflict: "company_id,email")
    }

    static func updateRecruiter(_ contact: Contact) async throws {
        try await write(method: "PATCH", path: "recruiters",
                        query: [URLQueryItem(name: "id", value: "eq.\(contact.id)")],
                        body: recruiterBody(contact))
    }

    static func deleteRecruiter(id: String) async throws {
        try await write(method: "DELETE", path: "recruiters",
                        query: [URLQueryItem(name: "id", value: "eq.\(id)")])
    }

    // MARK: - Per-user sent records (mail_sends)

    /// Append a send event to this user's history for `recruiterID`. Each call
    /// is a new row, so re-sending builds up the history rather than overwriting.
    static func recordSend(userEmail: String, recruiterID: String,
                           mail: SentMail, at date: Date) async throws {
        func value(_ s: String) -> Any { s.isEmpty ? NSNull() : s }
        let body: [String: Any] = [
            "user_email": userEmail,
            "recruiter_id": recruiterID,
            "sent_at": iso(date),
            "subject": value(mail.subject),
            "body": value(mail.body)
        ]
        try await write(method: "POST", path: "mail_sends", body: body)
    }

    // MARK: - Profile (per Gmail user)

    static func fetchProfile(email: String) async throws -> Profile? {
        let request = makeRequest(path: "profiles", query: [
            URLQueryItem(name: "select", value: "name,is_studying,college,is_working,company,position,resume_link"),
            URLQueryItem(name: "email", value: "eq.\(email)")
        ])
        let data = try await send(request)
        return try decoder.decode([Profile].self, from: data).first
    }

    static func upsertProfile(email: String, profile: Profile) async throws {
        let body: [String: Any] = [
            "email": email,
            "name": profile.name,
            "is_studying": profile.isStudying,
            "college": profile.college,
            "is_working": profile.isWorking,
            "company": profile.company,
            "position": profile.position,
            "resume_link": profile.resumeLink
        ]
        try await write(method: "POST", path: "profiles", body: body,
                        prefer: "return=minimal,resolution=merge-duplicates")
    }

    // MARK: - Templates (per Gmail user)

    static func fetchTemplates(userEmail: String) async throws -> [MailTemplate] {
        let request = makeRequest(path: "templates", query: [
            URLQueryItem(name: "select", value: "id,name,subject,content"),
            URLQueryItem(name: "user_email", value: "eq.\(userEmail)"),
            URLQueryItem(name: "order", value: "name")
        ])
        let data = try await send(request)
        return try decoder.decode([MailTemplate].self, from: data)
    }

    static func upsertTemplate(userEmail: String, template: MailTemplate) async throws {
        let body: [String: Any] = [
            "id": template.id.uuidString,
            "user_email": userEmail,
            "name": template.name,
            "subject": template.subject,
            "content": template.content
        ]
        try await write(method: "POST", path: "templates", body: body,
                        prefer: "return=minimal,resolution=merge-duplicates")
    }

    static func deleteTemplate(id: UUID) async throws {
        try await write(method: "DELETE", path: "templates",
                        query: [URLQueryItem(name: "id", value: "eq.\(id.uuidString)")])
    }

    /// A recruiter row body. Empty text fields become null so edits can clear a
    /// value. Sent state lives in `mail_sends`, not here.
    private static func recruiterBody(_ contact: Contact) -> [String: Any] {
        func value(_ s: String?) -> Any { (s?.isEmpty ?? true) ? NSNull() : s! }
        return [
            "name": value(contact.name),
            "email": value(contact.email),
            "position": value(contact.position),
            "phone": value(contact.phone)
        ]
    }

    // MARK: - Plumbing

    private static func makeRequest(path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(string: "\(AppConfig.supabaseURL)/rest/v1/\(path)")!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(AppConfig.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    @discardableResult
    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
            // A unique-constraint violation (Postgres 23505) means the name
            // already exists — surface a friendly message instead of raw SQL.
            if http.statusCode == 409 || body.contains("\"23505\"") {
                throw SupabaseError.duplicateCompany
            }
            throw SupabaseError.server(body)
        }
        return data
    }

    /// POST `body` and return the new row's `id`. When `onConflict` is given the
    /// insert upserts on those columns instead of failing on a duplicate.
    private static func insertReturningID(path: String, body: [String: Any],
                                          onConflict: String? = nil) async throws -> String {
        var query: [URLQueryItem] = []
        var prefer = "return=representation"
        if let onConflict {
            query.append(URLQueryItem(name: "on_conflict", value: onConflict))
            prefer += ",resolution=merge-duplicates"
        }
        var request = makeRequest(path: path, query: query)
        request.httpMethod = "POST"
        request.setValue(prefer, forHTTPHeaderField: "Prefer")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        struct Row: Decodable { let id: String }
        guard let row = try decoder.decode([Row].self, from: data).first else {
            throw SupabaseError.badResponse
        }
        return row.id
    }

    private static func write(method: String, path: String,
                              query: [URLQueryItem] = [], body: [String: Any]? = nil,
                              prefer: String = "return=minimal", onConflict: String? = nil) async throws {
        var query = query
        if let onConflict { query.append(URLQueryItem(name: "on_conflict", value: onConflict)) }
        var request = makeRequest(path: path, query: query)
        request.httpMethod = method
        request.setValue(prefer, forHTTPHeaderField: "Prefer")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        try await send(request)
    }

    // MARK: - Date handling

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let raw = try dec.singleValueContainer().decode(String.self)
            if let date = parseTimestamp(raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath,
                                                    debugDescription: "Unrecognized date: \(raw)"))
        }
        return decoder
    }()

    /// Parse a Postgres timestamptz, tolerating fractional seconds and the space
    /// separator Postgres sometimes emits instead of "T".
    private static func parseTimestamp(_ string: String) -> Date? {
        let normalized = string.replacingOccurrences(of: " ", with: "T")

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: normalized) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: normalized) { return date }

        // Microsecond precision (6+ fractional digits) that ISO8601DateFormatter
        // rejects — trim the fractional part and retry.
        if let dot = normalized.firstIndex(of: "."),
           let tzStart = normalized[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let trimmed = String(normalized[..<dot]) + String(normalized[tzStart...])
            return plain.date(from: trimmed)
        }
        return nil
    }
}

enum SupabaseError: LocalizedError {
    case badResponse
    case duplicateCompany
    case server(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Unexpected response from the server."
        case .duplicateCompany: return "A company with that name already exists."
        case .server(let message): return message
        }
    }
}

extension Error {
    /// True when a request was cancelled (e.g. a view-driven reload was
    /// interrupted by a tab switch) — never a real failure worth surfacing.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}
