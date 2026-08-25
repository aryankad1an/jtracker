import SwiftUI

/// A read-only summary of a cold mail that was sent: who it went to, when, and
/// the exact subject and body that were delivered. Shown from the Activity tab
/// and from a company's Sent section.
struct MailSummaryView: View {
    let contact: Contact
    let company: String

    @Environment(\.dismiss) private var dismiss

    private var recipientName: String {
        contact.name.isEmpty ? contact.email : contact.name
    }

    /// Full date + time, e.g. "Aug 14, 2026 at 3:42 PM".
    private var sentStamp: String? {
        contact.sentAt?.formatted(date: .abbreviated, time: .shortened)
    }

    /// Full date + time of the reply, when there was one.
    private var repliedStamp: String? {
        contact.repliedAt?.formatted(date: .abbreviated, time: .shortened)
    }

    /// How long they took to answer, in whole days.
    private var turnaround: String? {
        guard let sent = contact.sentAt, let replied = contact.repliedAt,
              let days = Calendar.current.dateComponents([.day], from: sent, to: replied).day else {
            return nil
        }
        return days == 0 ? "Same day" : "\(days) day\(days == 1 ? "" : "s")"
    }

    /// The answer, when one arrived. Only the opening lines are stored — enough to
    /// recognise the reply and decide whether to open Gmail, without this app
    /// keeping a copy of someone else's mail.
    @ViewBuilder
    private var replySection: some View {
        if let repliedStamp {
            Section {
                LabeledContent("When", value: repliedStamp)
                if let turnaround {
                    LabeledContent("Turnaround", value: turnaround)
                }
                if let from = contact.replyFrom, !from.isEmpty {
                    LabeledContent("From", value: from)
                }
                if let snippet = contact.replySnippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            } header: {
                Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                    .foregroundStyle(.statusDone)
            } footer: {
                Text("Detected in the Gmail thread this mail started. Open Gmail for the full message.")
            }
        }
    }

    var body: some View {
        NavigationStack {
            PaperList {
                Section("To") {
                    LabeledContent("Name", value: recipientName)
                    if !contact.email.isEmpty {
                        LabeledContent("Email", value: contact.email)
                    }
                    LabeledContent("Company", value: company)
                    if !contact.position.isEmpty {
                        LabeledContent("Position", value: contact.position)
                    }
                }

                Section("Sent") {
                    LabeledContent("When", value: sentStamp ?? "Date not recorded")
                }

                replySection

                if let subject = contact.sentSubject, !subject.isEmpty {
                    Section("Subject") {
                        Text(subject)
                    }
                }

                if let body = contact.sentBody, !body.isEmpty {
                    Section("Message") {
                        Text(body)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                } else {
                    Section("Message") {
                        Text("Message content wasn't recorded for this mail.")
                            .foregroundStyle(.inkMuted)
                    }
                }
            }
            .navigationTitle("Sent Mail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Haptics.tap(0.5)
                        dismiss()
                    }
                }
            }
        }
    }
}
