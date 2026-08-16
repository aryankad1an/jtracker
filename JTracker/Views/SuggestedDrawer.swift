import SwiftUI

/// The Suggested drawer: every company with contacts you can cold-mail (and
/// haven't in the last month), each showing how many people to reach out to.
///
/// Reuses `List`'s own multi-select (native selection circles driven by
/// `editMode`) — the same pattern `CompaniesView` uses — rather than hand-rolled
/// checkboxes. The company filter and "Select"/"Send to All" all live under one
/// ⋯ menu; tapping a company (outside selection) pushes to its own list of
/// suggested emails.
struct SuggestedDrawer: View {
    @Environment(JobStore.self) private var jobStore
    @Environment(\.dismiss) private var dismiss

    /// nil = every company shown.
    @State private var companyFilter: String?
    @State private var isSelecting = false
    @State private var selection = Set<String>()   // selected company ids
    @State private var sendBatch: SendBatch?

    private var groups: [(company: Job, contacts: [Contact])] {
        jobStore.suggestedGroups
    }

    /// Groups matching the current company filter (all when none is set).
    private var filtered: [(company: Job, contacts: [Contact])] {
        guard let companyFilter else { return groups }
        return groups.filter { $0.company.id == companyFilter }
    }

    private func recipients(
        for targets: [(company: Job, contacts: [Contact])]
    ) -> [(contact: Contact, company: String)] {
        targets.flatMap { target in
            target.contacts.map { (contact: $0, company: target.company.company) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    ContentUnavailableView(
                        "All caught up",
                        systemImage: "checkmark.circle",
                        description: Text("Everyone reachable has been mailed in the last month.")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView(
                        "No Matches",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("No suggested company matches this filter.")
                    )
                } else {
                    List(selection: $selection) {
                        ForEach(filtered, id: \.company.id) { group in
                            NavigationLink {
                                CompanySuggestedDrawer(company: group.company, contacts: group.contacts)
                            } label: {
                                SuggestedCompanyRow(group: group)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
                }
            }
            .navigationTitle(companyFilter.map { "Suggested · \($0)" } ?? "Suggested")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if !groups.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        if isSelecting {
                            GlassDoneButton { exitSelection() }
                        } else {
                            menu
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting { sendSelectedBar }
            }
            .sheet(item: $sendBatch) { batch in
                SuggestedSendView(recipients: batch.recipients)
            }
        }
    }

    private var menu: some View {
        Menu {
            Menu {
                Button {
                    companyFilter = nil
                } label: {
                    if companyFilter == nil {
                        Label("All Companies", systemImage: "checkmark")
                    } else {
                        Text("All Companies")
                    }
                }
                ForEach(groups, id: \.company.id) { group in
                    Button {
                        companyFilter = group.company.id
                    } label: {
                        if companyFilter == group.company.id {
                            Label(group.company.company, systemImage: "checkmark")
                        } else {
                            Text(group.company.company)
                        }
                    }
                }
            } label: {
                Label("Filter by Company", systemImage: "line.3.horizontal.decrease.circle")
            }

            Button {
                enterSelection()
            } label: {
                Label("Select Companies", systemImage: "checkmark.circle")
            }

            Button {
                sendBatch = SendBatch(recipients: recipients(for: groups))
            } label: {
                Label("Send to All", systemImage: "paperplane.fill")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func enterSelection() {
        selection = []
        withAnimation { isSelecting = true }
    }

    private func exitSelection() {
        withAnimation { isSelecting = false }
        selection = []
    }

    /// Send bar shown only while selecting. Targets are resolved from the full
    /// `groups` (not the filter), so a selection survives switching filters.
    private var sendSelectedBar: some View {
        let targets = groups.filter { selection.contains($0.company.id) }
        let people = targets.reduce(0) { $0 + $1.contacts.count }
        return VStack(spacing: 0) {
            Divider()
            Button {
                sendBatch = SendBatch(recipients: recipients(for: targets))
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "paperplane.fill")
                    Text(selection.isEmpty
                         ? "Select companies to send"
                         : "Send to \(selection.count) selected (\(people))")
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selection.isEmpty)
            .padding()
        }
        .background(.bar)
    }
}

/// A batch of recipients to send to — everyone or just the current selection.
/// Wrapped so it can drive `.sheet(item:)`.
private struct SendBatch: Identifiable {
    let id = UUID()
    let recipients: [(contact: Contact, company: String)]
}

/// A suggested-company row: monogram, name, and how many people to reach out to.
private struct SuggestedCompanyRow: View {
    let group: (company: Job, contacts: [Contact])

    var body: some View {
        HStack(spacing: 12) {
            MonogramAvatar(text: group.company.company, size: Theme.Avatar.small,
                           systemImage: "building.2.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(group.company.company)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(group.contacts.count) to reach out")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The per-company screen: the emails suggested for one company. Pushed from the
/// Suggested drawer's list, so the system back button returns to it.
struct CompanySuggestedDrawer: View {
    let company: Job
    let contacts: [Contact]

    var body: some View {
        Group {
            if contacts.isEmpty {
                ContentUnavailableView("Nothing to send", systemImage: "envelope")
            } else {
                List {
                    ForEach(contacts) { contact in
                        SuggestedContactRow(contact: contact)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(company.company)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One suggested contact: name, email, and a chip marking never-mailed ("New")
/// from previously-mailed (last-sent date). Shared by the per-company screen.
struct SuggestedContactRow: View {
    let contact: Contact

    private var title: String {
        contact.name.isEmpty ? contact.email : contact.name
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(contact.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let sentAt = contact.sentAt {
                chip("Sent \(sentAt.activityLabel)", system: "clock.arrow.circlepath", color: .secondary)
            } else {
                chip("New", system: "sparkle", color: .accentColor)
            }
        }
    }

    private func chip(_ text: String, system: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: system)
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}
