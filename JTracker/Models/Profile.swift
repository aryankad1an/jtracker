import Foundation

/// The user's own profile details, stored in Supabase keyed by their Gmail
/// address so it follows them across devices.
struct Profile: Codable {
    var name = ""

    var isStudying = false
    var college = ""

    var isWorking = false
    var company = ""
    var position = ""

    var resumeLink = ""

    enum CodingKeys: String, CodingKey {
        case name
        case isStudying = "is_studying"
        case college
        case isWorking = "is_working"
        case company
        case position
        case resumeLink = "resume_link"
    }

    init() {}

    /// Rows may omit columns; decode leniently so a partial row still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isStudying = try c.decodeIfPresent(Bool.self, forKey: .isStudying) ?? false
        college = try c.decodeIfPresent(String.self, forKey: .college) ?? ""
        isWorking = try c.decodeIfPresent(Bool.self, forKey: .isWorking) ?? false
        company = try c.decodeIfPresent(String.self, forKey: .company) ?? ""
        position = try c.decodeIfPresent(String.self, forKey: .position) ?? ""
        resumeLink = try c.decodeIfPresent(String.self, forKey: .resumeLink) ?? ""
    }
}

/// One "sent" record: this Gmail user sent a mail to this recruiter. Each send
/// is its own row, so the same recruiter can have many (the send history).
struct MailSend: Decodable, Identifiable {
    let id: String
    let recruiterID: String
    let sentAt: Date?
    let subject: String?
    let body: String?

    enum CodingKeys: String, CodingKey {
        case id
        case recruiterID = "recruiter_id"
        case sentAt = "sent_at"
        case subject, body
    }
}
