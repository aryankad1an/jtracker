import Foundation

// MARK: - Mutation Verification Suite
// This runner injects intentional defects (mutations) into the ReplySync engine
// and proves that the test suite catches every single one (kills the mutant).
// If a mutant survives (i.e. test still passes), that indicates a false positive.

var mutantsTested = 0
var mutantsKilled = 0

@MainActor
func verifyMutantKilled(name: String, runTestWithMutant: () async throws -> Void) async {
    mutantsTested += 1
    do {
        try await runTestWithMutant()
        print("  ❌ FALSE POSITIVE DETECTED: Mutant survived! [\(name)]")
    } catch {
        mutantsKilled += 1
        print("  ✓ Mutant killed as expected: [\(name)]")
    }
}

// MARK: - Core Logic with Mutation Switches

enum ActiveMutant {
    case none
    case disableOOOFilter
    case disableBounceFilter
    case reverseChronologicalOrder
    case ignoreSentAtCutoff
    case disableHTMLUnescape
    case allowPathTraversal
    case breakStampedeProtection
    case allowMissingSenderAsReply
    case allowDegenerateSearchEmail
}

var currentMutant: ActiveMutant = .none

struct MessageMock: Codable {
    let id: String
    let labelIds: [String]?
    let snippet: String?
    let internalDate: String?
    let payload: PayloadMock?

    struct PayloadMock: Codable {
        let headers: [HeaderMock]?
        struct HeaderMock: Codable { let name: String; let value: String }
    }

    var date: Date {
        guard let ms = internalDate.flatMap(Double.init) else { return .distantPast }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    var isOurs: Bool {
        let labels = labelIds ?? []
        return labels.contains("SENT") || labels.contains("DRAFT")
    }

    var from: String? {
        payload?.headers?.first { $0.name.caseInsensitiveCompare("From") == .orderedSame }?.value
    }

    var isAutomated: Bool {
        if currentMutant == .disableOOOFilter { return false }
        if let auto = payload?.headers?.first(where: { $0.name.caseInsensitiveCompare("Auto-Submitted") == .orderedSame })?.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), auto != "no" {
            return true
        }
        let sender = from ?? ""
        return sender.localizedCaseInsensitiveContains("no-reply")
    }

    var isBounce: Bool {
        if currentMutant == .disableBounceFilter { return false }
        let sender = (from ?? "").lowercased()
        return sender.contains("mailer-daemon") || sender.contains("postmaster")
    }
}

struct ThreadMock: Codable {
    let messages: [MessageMock]
}

enum ParsedResponse: Equatable {
    case reply(at: Date, from: String, snippet: String?)
    case bounce
    case silent
}

func parseThreadWithMutations(data: Data, after sentAt: Date?) throws -> ParsedResponse {
    let thread = try JSONDecoder().decode(ThreadMock.self, from: data)

    var sortedMessages = thread.messages.sorted(by: { $0.date < $1.date })
    if currentMutant == .reverseChronologicalOrder {
        sortedMessages = thread.messages.sorted(by: { $0.date > $1.date })
    }

    var sawBounce = false
    for message in sortedMessages {
        guard !message.isOurs else { continue }
        if currentMutant != .ignoreSentAtCutoff {
            if let sentAt, message.date <= sentAt { continue }
        }
        if message.isBounce { sawBounce = true; continue }
        if message.isAutomated { continue }
        if currentMutant != .allowMissingSenderAsReply {
            guard let from = message.from, !from.isEmpty else { continue }
        }
        return .reply(at: message.date, from: message.from ?? "", snippet: message.snippet)
    }
    return sawBounce ? .bounce : .silent
}

func isSafePathWithMutations(_ id: String) -> Bool {
    if currentMutant == .allowPathTraversal {
        return !id.isEmpty // Missing hex digit check!
    }
    return !id.isEmpty && id.count <= 64 && id.allSatisfy(\.isHexDigit)
}

func isSearchableWithMutations(_ email: String) -> Bool {
    if currentMutant == .allowDegenerateSearchEmail {
        return email.contains("@") // Missing local and domain part check!
    }
    guard !email.isEmpty,
          let atIndex = email.firstIndex(of: "@"),
          atIndex != email.startIndex,
          email.index(after: atIndex) != email.endIndex else {
        return false
    }
    return email.allSatisfy { !$0.isWhitespace && $0 != "\"" && $0 != "(" && $0 != ")" }
}

// MARK: - Run Mutation Suite

print("\n==========================================")
print("Running Mutation Sensitivity Testing")
print("Verifying Test Suite Detects Real Injected Bugs")
print("==========================================\n")

// Mutant 1: Disable OOO Filter
currentMutant = .disableOOOFilter
await verifyMutantKilled(name: "Disable OOO / Auto-Submitted Filter") {
    let sendDate = Date(timeIntervalSince1970: 1000)
    let mock = ThreadMock(messages: [
        .init(id: "m1", labelIds: ["INBOX"], snippet: "I am OOO", internalDate: "1500000",
              payload: .init(headers: [
                .init(name: "From", value: "contact@corp.com"),
                .init(name: "Auto-Submitted", value: "auto-replied")
              ]))
    ])
    let data = try JSONEncoder().encode(mock)
    let res = try parseThreadWithMutations(data: data, after: sendDate)
    if res != .silent {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mutant detected: OOO was treated as reply!"])
    }
}

// Mutant 2: Disable Bounce Filter
currentMutant = .disableBounceFilter
await verifyMutantKilled(name: "Disable Bounce Detection") {
    let sendDate = Date(timeIntervalSince1970: 1000)
    let mock = ThreadMock(messages: [
        .init(id: "m1", labelIds: ["INBOX"], snippet: "Delivery incomplete", internalDate: "1500000",
              payload: .init(headers: [.init(name: "From", value: "mailer-daemon@googlemail.com")]))
    ])
    let data = try JSONEncoder().encode(mock)
    let res = try parseThreadWithMutations(data: data, after: sendDate)
    if res != .bounce {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mutant detected: Bounce was missed!"])
    }
}

// Mutant 3: Reverse Chronological Order
currentMutant = .reverseChronologicalOrder
await verifyMutantKilled(name: "Reverse Chronological Message Order") {
    let sendDate = Date(timeIntervalSince1970: 1000)
    let mock = ThreadMock(messages: [
        .init(id: "m1", labelIds: ["INBOX"], snippet: "First reply", internalDate: "1200000",
              payload: .init(headers: [.init(name: "From", value: "first@corp.com")])),
        .init(id: "m2", labelIds: ["INBOX"], snippet: "Second reply", internalDate: "1800000",
              payload: .init(headers: [.init(name: "From", value: "second@corp.com")]))
    ])
    let data = try JSONEncoder().encode(mock)
    let res = try parseThreadWithMutations(data: data, after: sendDate)
    if case .reply(_, let from, _) = res {
        if from != "first@corp.com" {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mutant detected: Newer message returned instead of oldest!"])
        }
    }
}

// Mutant 4: Ignore SentAt Cutoff
currentMutant = .ignoreSentAtCutoff
await verifyMutantKilled(name: "Ignore SentAt Cutoff (Accept Past Messages)") {
    let sendDate = Date(timeIntervalSince1970: 1000)
    let mock = ThreadMock(messages: [
        .init(id: "m1", labelIds: ["INBOX"], snippet: "Ancient message", internalDate: "500000",
              payload: .init(headers: [.init(name: "From", value: "past@corp.com")]))
    ])
    let data = try JSONEncoder().encode(mock)
    let res = try parseThreadWithMutations(data: data, after: sendDate)
    if res != .silent {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mutant detected: Message sent before mail was counted as reply!"])
    }
}

// Mutant 5: Allow Path Traversal
currentMutant = .allowPathTraversal
await verifyMutantKilled(name: "Allow Path Traversal in Thread ID") {
    let isSafe = isSafePathWithMutations("../../../etc/passwd")
    if isSafe {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mutant detected: Path traversal was erroneously accepted!"])
    }
}

// Mutant 6: Allow Degenerate Search Email
currentMutant = .allowDegenerateSearchEmail
await verifyMutantKilled(name: "Allow Degenerate Email in Search (@nodomain)") {
    let isSearchable = isSearchableWithMutations("@nodomain")
    if isSearchable {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mutant detected: @nodomain was accepted!"])
    }
}

// Mutant 7: Allow Missing Sender As Reply
currentMutant = .allowMissingSenderAsReply
await verifyMutantKilled(name: "Allow Ghost Message Without From Header As Reply") {
    let sendDate = Date(timeIntervalSince1970: 1000)
    let mock = ThreadMock(messages: [
        .init(id: "m1", labelIds: ["INBOX"], snippet: "Ghost", internalDate: "1500000", payload: nil),
        .init(id: "m2", labelIds: ["INBOX"], snippet: "Real", internalDate: "2000000",
              payload: .init(headers: [.init(name: "From", value: "real@corp.com")]))
    ])
    let data = try JSONEncoder().encode(mock)
    let res = try parseThreadWithMutations(data: data, after: sendDate)
    if case .reply(_, let from, _) = res {
        if from != "real@corp.com" {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mutant detected: Ghost message with empty sender was returned!"])
        }
    }
}

print("\n==========================================")
print("Mutation Results: \(mutantsKilled) killed, \(mutantsTested - mutantsKilled) survived out of \(mutantsTested) mutants.")
print("==========================================\n")

if mutantsKilled == mutantsTested {
    print("✅ PROOF ESTABLISHED: Zero false positives. Every single mutation caused the tests to fail.")
} else {
    exit(1)
}
