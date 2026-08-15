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

    var body: some View {
        NavigationStack {
            List {
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
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Sent Mail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
