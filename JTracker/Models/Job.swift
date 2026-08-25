import Foundation

/// A cold-mail outreach entry inside a company, backed by a Supabase
/// `recruiters` row. `id` is the row's UUID (empty for a not-yet-saved draft).
struct Contact: Identifiable, Decodable {
    var id: String = ""

    var email = ""
    var name = ""
    var phone: String?
    var position = ""
    /// False when the address bounces or the person has left the company. Part of
    /// the shared recruiter row, not per-user: a dead address is dead for everyone.
    /// Invalid contacts are never suggested and can't be mailed — see
    /// `JobStore.setValidity`.
    var isValid = true
    // Sent state is per-user (from `mail_sends`), overlaid after decoding —
    // never part of the shared recruiter row.
    var isSent = false
    var sentAt: Date?        // when it was sent
    var sentSubject: String? // the rendered subject that went out
    var sentBody: String?    // the rendered body that went out
    /// Reply state for the latest send, overlaid from `mail_sends` alongside the
    /// sent state above. Per-user for the same reason: whether a recruiter wrote
    /// back is a fact about this user's mailbox, not about the shared contact.
    var repliedAt: Date?
    var replyFrom: String?
    var replySnippet: String?

    enum CodingKeys: String, CodingKey {
        case id, email, name, phone, position
        case isValid = "is_valid"
    }

    init(id: String = "", email: String = "", name: String = "", phone: String? = nil,
         position: String = "", isValid: Bool = true, isSent: Bool = false, sentAt: Date? = nil,
         sentSubject: String? = nil, sentBody: String? = nil,
         repliedAt: Date? = nil, replyFrom: String? = nil, replySnippet: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
        self.phone = phone
        self.position = position
        self.isValid = isValid
        self.isSent = isSent
        self.sentAt = sentAt
        self.sentSubject = sentSubject
        self.sentBody = sentBody
        self.repliedAt = repliedAt
        self.replyFrom = replyFrom
        self.replySnippet = replySnippet
    }

    /// Whether this contact wrote back to the last mail we sent them.
    var hasReplied: Bool { repliedAt != nil }

    /// Rows carry nulls for optional columns, so decode leniently and default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        phone = try c.decodeIfPresent(String.self, forKey: .phone)
        position = try c.decodeIfPresent(String.self, forKey: .position) ?? ""
        // Rows written before the column existed come back null — those are valid.
        isValid = try c.decodeIfPresent(Bool.self, forKey: .isValid) ?? true
    }
}

/// The rendered mail that was actually sent to a contact.
struct SentMail {
    let subject: String
    let body: String
    /// What Gmail called the message it just sent. `threadID` is the handle reply
    /// detection is built on — every reply lands in the same thread, whoever sends
    /// it — so it's captured at send time rather than searched for afterwards.
    var gmailMessageID: String?
    var gmailThreadID: String?
}

/// One entry in the Activity feed: a single mail the user sent, with the
/// recruiter, company name, and that send's subject/body/date. One per send (so
/// repeat sends to the same recruiter are separate rows). Built from the send
/// history directly, so it stays visible even after the company leaves Home.
struct ActivityEntry: Identifiable {
    let id: String        // the send's id (unique per send)
    let company: String
    let contact: Contact
    var date: Date? { contact.sentAt }
}

/// One company the user is tracking, backed by a Supabase `companies` row, with
/// its cold mails (recruiters).
struct Job: Identifiable, Decodable {
    var id: String = ""
    var company: String
    /// The company's sector/industry, when known. Only fetched for the full
    /// catalog (the Companies list); nil on the tracked-companies query.
    var sector: String?
    var contacts: [Contact] = []

    enum CodingKeys: String, CodingKey {
        case id
        case company = "name"
        case sector
        case contacts = "recruiters"
    }

    init(id: String, company: String, sector: String? = nil, contacts: [Contact] = []) {
        self.id = id
        self.company = company
        self.sector = sector
        self.contacts = contacts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        company = try c.decode(String.self, forKey: .company)
        sector = try c.decodeIfPresent(String.self, forKey: .sector)
        contacts = try c.decodeIfPresent([Contact].self, forKey: .contacts) ?? []
    }

    /// The cold mails still worth sending, and the ones marked invalid. The company
    /// screen shows them as two groups and only ever mails the first.
    var validContacts: [Contact] { contacts.filter(\.isValid) }
    var invalidContacts: [Contact] { contacts.filter { !$0.isValid } }

    /// Contacts at this company who wrote back, and the ones still silent after
    /// being mailed. Both drive Insights; neither counts anyone never mailed.
    var repliedContacts: [Contact] { contacts.filter(\.hasReplied) }
    var awaitingContacts: [Contact] { contacts.filter { $0.isSent && !$0.hasReplied } }

    /// Whether this company answers a search box. Matching runs over the people
    /// inside as well as the company itself, so a half-remembered recruiter's name
    /// finds the company you'd have to have remembered to find them — the same
    /// predicate on Home and in the catalog, so a query that works on one screen
    /// works on the other.
    ///
    /// `query` is expected to be already trimmed; an empty one matches nothing,
    /// because "no query" is a decision for the caller, not for a filter.
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return false }
        if company.localizedCaseInsensitiveContains(query) { return true }
        if sector?.localizedCaseInsensitiveContains(query) == true { return true }
        return contacts.contains { contact in
            contact.name.localizedCaseInsensitiveContains(query)
                || contact.email.localizedCaseInsensitiveContains(query)
                || contact.position.localizedCaseInsensitiveContains(query)
        }
    }
}
