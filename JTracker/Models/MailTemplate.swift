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

    /// Chip text in the editor. The tokens themselves are too long to read on a
    /// keyboard bar, and "Their"/"My" says which side of the mail a value comes
    /// from far faster than "Receiver"/"Sender" does.
    var shortLabel: String {
        switch self {
        case .receiverName: "Their name"
        case .receiverPosition: "Their role"
        case .receiverCompany: "Their company"
        case .senderName: "My name"
        case .senderCollege: "My college"
        case .senderCompany: "My company"
        case .senderPosition: "My role"
        case .senderResume: "Resume link"
        }
    }

    /// How a blank value is called out in the preview: "⟨their role missing⟩".
    var blankLabel: String {
        switch self {
        case .receiverName: "their name"
        case .receiverPosition: "their role"
        case .receiverCompany: "their company"
        case .senderName: "your name"
        case .senderCollege: "your college"
        case .senderCompany: "your company"
        case .senderPosition: "your role"
        case .senderResume: "resume link"
        }
    }
}

/// The concrete values used to replace placeholder tokens when composing.
struct MailContext {
    /// Maps each placeholder to the value it should be replaced with.
    var values: [MailPlaceholder: String] = [:]

    /// Replace every placeholder token in `text` with its value (empty if unset).
    ///
    /// Also cleans up stray Unicode line separators (see `sanitizedLineSeparators`)
    /// so templates saved before that fix — which may have baked-in ones from the
    /// keyboard bug — render correctly too, not just newly-saved ones.
    func fill(_ text: String) -> String {
        MailPlaceholder.allCases.reduce(text) { result, placeholder in
            result.replacingOccurrences(of: placeholder.token, with: values[placeholder] ?? "")
        }.sanitizedLineSeparators
    }

    /// Build a context from a recipient contact, its company, and the sender profile.
    static func make(contact: Contact, company: String, profile: Profile) -> MailContext {
        MailContext(values: [
            .receiverName: RecipientName.greeting(name: contact.name, email: contact.email),
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
