import Foundation

/// One problem found in a template, ranked so the editor can lead with whatever
/// would embarrass the sender most.
struct TemplateFinding: Identifiable, Hashable {
    enum Severity: Int, Comparable {
        /// Ships to the recruiter as visibly broken text.
        case error = 0
        /// Renders as a silent gap — grammatical damage, but not obviously a bug.
        case warning = 1

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let severity: Severity
    let title: String
    let detail: String
    /// The literal text at fault, when there is one to point at.
    let token: String?
    /// A known token this looks like a misspelling of — offered as a one-tap fix.
    let suggestion: String?
}

/// Checks a template for the three ways it can quietly produce a bad mail:
/// tokens that aren't real (they ship literally), tokens the sender's own profile
/// can't fill (they render blank in every mail), and tokens some recipients have
/// no data for (they render blank for just those people).
///
/// None of this is knowable from the template text alone, which is why it takes
/// the profile and the contact catalog: the same template is fine for one user
/// and broken for another.
enum TemplateDiagnostics {

    static func analyze(subject: String, content: String,
                        profile: Profile, contacts: [Contact]) -> [TemplateFinding] {
        var findings: [TemplateFinding] = []
        let text = subject + "\n" + content

        findings += unknownTokenFindings(in: text)
        findings += unclosedBraceFindings(in: text)

        let used = Set(MailPlaceholder.allCases.filter { text.contains($0.token) })
        findings += profileGapFindings(used: used, profile: profile)
        findings += recipientGapFindings(used: used, contacts: contacts)

        return findings.sorted { ($0.severity, $0.id) < ($1.severity, $1.id) }
    }

    // MARK: - Tokens that aren't real

    /// Anything in braces that isn't a known placeholder. `MailContext.fill` only
    /// swaps exact matches, so `{Receiver-name}` survives into the sent mail and
    /// the recruiter reads the raw token.
    private static func unknownTokenFindings(in text: String) -> [TemplateFinding] {
        let known = Set(MailPlaceholder.allCases.map(\.token))
        var seen = Set<String>()
        var findings: [TemplateFinding] = []

        for literal in bracedRuns(in: text) where !known.contains(literal) {
            guard seen.insert(literal).inserted else { continue }
            let suggestion = closestToken(to: literal)
            findings.append(TemplateFinding(
                id: "unknown-\(literal)",
                severity: .error,
                title: "\(literal) isn't a placeholder",
                detail: suggestion.map { "It will be sent exactly as written. Did you mean \($0)?" }
                    ?? "It will be sent to the recruiter exactly as written, braces and all.",
                token: literal,
                suggestion: suggestion
            ))
        }
        return findings
    }

    /// A `{` with no closing `}` never even looks like a token, so it slips past
    /// the check above while still shipping literally.
    private static func unclosedBraceFindings(in text: String) -> [TemplateFinding] {
        let opens = text.filter { $0 == "{" }.count
        let closes = text.filter { $0 == "}" }.count
        guard opens != closes else { return [] }
        return [TemplateFinding(
            id: "unbalanced-braces",
            severity: .error,
            title: "Unclosed placeholder",
            detail: "There \(opens > closes ? "are more { than }" : "are more } than {") in this template. "
                + "An unclosed placeholder is sent as plain text.",
            token: nil,
            suggestion: nil
        )]
    }

    // MARK: - Tokens the sender can't fill

    /// Sender-side tokens read from the profile, which onboarding only requires a
    /// name for — so a template can reference a resume link the account has never
    /// set, and every mail goes out with a hole where the link should be.
    private static func profileGapFindings(used: Set<MailPlaceholder>,
                                           profile: Profile) -> [TemplateFinding] {
        senderFields(profile).compactMap { placeholder, value, label in
            guard used.contains(placeholder), value.trimmingCharacters(in: .whitespaces).isEmpty else {
                return nil
            }
            return TemplateFinding(
                id: "profile-\(placeholder.rawValue)",
                severity: .warning,
                title: "Your profile has no \(label)",
                detail: "\(placeholder.token) will be blank in every mail from this template. "
                    + "Add it in Profile, or take the placeholder out.",
                token: placeholder.token,
                suggestion: nil
            )
        }
    }

    private static func senderFields(_ profile: Profile) -> [(MailPlaceholder, String, String)] {
        [
            (.senderName, profile.name, "name"),
            (.senderCollege, profile.college, "college"),
            (.senderCompany, profile.company, "company"),
            (.senderPosition, profile.position, "position"),
            (.senderResume, profile.resumeLink, "resume link")
        ]
    }

    // MARK: - Tokens some recipients can't fill

    /// Receiver-side gaps are per-contact, so this reports how much of the catalog
    /// is affected rather than a yes/no. `{Receiver-Name}` is deliberately absent:
    /// `RecipientName` guarantees it a value, so it can't come out blank.
    private static func recipientGapFindings(used: Set<MailPlaceholder>,
                                             contacts: [Contact]) -> [TemplateFinding] {
        guard used.contains(.receiverPosition), !contacts.isEmpty else { return [] }
        let missing = contacts.filter { $0.position.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !missing.isEmpty else { return [] }

        return [TemplateFinding(
            id: "recipients-position",
            severity: .warning,
            title: "\(missing.count) of \(contacts.count) contacts have no position",
            detail: "\(MailPlaceholder.receiverPosition.token) will be blank for them — "
                + "check the preview reads correctly with it empty.",
            token: MailPlaceholder.receiverPosition.token,
            suggestion: nil
        )]
    }

    // MARK: - Text scanning

    /// Every `{...}` run in the text, in order of appearance.
    static func bracedRuns(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\{[^{}]*\\}") else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// The known token a misspelling most likely meant.
    ///
    /// Tries a normalized match first — stripping case and separators catches the
    /// common slips (`{receiver name}`, `{ReceiverName}`) exactly — then falls back
    /// to edit distance for genuine typos like `{Reciever-Name}`.
    static func closestToken(to literal: String) -> String? {
        let normalize = { (s: String) in
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let target = normalize(literal)
        guard !target.isEmpty else { return nil }

        for placeholder in MailPlaceholder.allCases where normalize(placeholder.token) == target {
            return placeholder.token
        }

        let scored = MailPlaceholder.allCases
            .map { ($0.token, editDistance(target, normalize($0.token))) }
            .min { $0.1 < $1.1 }
        // Allow roughly one slip per five characters, so short tokens don't match
        // everything and long ones tolerate a real typo.
        guard let (token, distance) = scored, distance <= max(2, target.count / 5) else { return nil }
        return token
    }

    /// Levenshtein distance, two rows at a time.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
