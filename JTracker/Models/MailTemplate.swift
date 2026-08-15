import Foundation

/// A reusable mail preset with placeholder tokens in its subject/content.
struct MailTemplate: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var subject: String
    var content: String
}

/// Placeholder tokens that can be dropped into a template and later filled in.
enum MailPlaceholder: String, CaseIterable, Identifiable {
    case receiverName = "{Receiver-Name}"
    case receiverPosition = "{Receiver-Position}"
    case receiverCompany = "{Receiver-Company}"
    case senderName = "{Sender-Name}"
    case senderCollege = "{Sender-College}"
    case senderCompany = "{Sender-Company}"
    case senderPosition = "{Sender-Position}"
    case senderResume = "{Resume-Link}"

    var id: String { rawValue }
    var token: String { rawValue }
}

/// The concrete values used to replace placeholder tokens when composing.
struct MailContext {
    /// Maps each placeholder to the value it should be replaced with.
    var values: [MailPlaceholder: String] = [:]

    /// Replace every placeholder token in `text` with its value (empty if unset).
    func fill(_ text: String) -> String {
        MailPlaceholder.allCases.reduce(text) { result, placeholder in
            result.replacingOccurrences(of: placeholder.token, with: values[placeholder] ?? "")
        }
    }

    /// Build a context from a recipient contact, its company, and the sender profile.
    static func make(contact: Contact, company: String, profile: Profile) -> MailContext {
        MailContext(values: [
            .receiverName: contact.name.split(separator: " ").first.map(String.init) ?? contact.name,
            .receiverPosition: contact.position,
            .receiverCompany: company,
            .senderName: profile.name,
            .senderCollege: profile.college,
            .senderCompany: profile.company,
            .senderPosition: profile.position,
            .senderResume: profile.resumeLink
        ])
    }
}
