import SwiftUI

/// The Activity tab: a log of the cold mails you've sent, newest first, with a
/// glass company filter on top. Tapping a row opens the "Sent Mail" drawer.
struct ActivityView: View {
    @Environment(JobStore.self) private var jobStore

    @State private var summaryItem: ActivityEntry?
    @State private var selectedCompany: String?

    /// Distinct companies that have activity, for the filter.
    private var companies: [String] {
        Array(Set(jobStore.activity.map(\.company)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Items shown for the current company filter (all when none is selected).
    private var visibleItems: [ActivityEntry] {
        guard let company = selectedCompany else { return jobStore.activity }
        return jobStore.activity.filter { $0.company == company }
    }

    var body: some View {
        NavigationStack {
            Group {
                if jobStore.activity.isEmpty {
                    ContentUnavailableView(
                        "Nothing here yet",
                        systemImage: "tray",
                        description: Text("Cold mails you send will show up here.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(visibleItems) { item in
                            ActivityRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture { summaryItem = item }
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    companyFilter
                }
            }
            .sheet(item: $summaryItem) { item in
                MailSummaryView(contact: item.contact, company: item.company)
            }
        }
    }

    /// The leading toolbar filter — same glass treatment as Home's trailing menu,
    /// just on the left. Lists every company with activity (plus "All Companies").
    private var companyFilter: some View {
        Menu {
            Button { selectedCompany = nil } label: {
                Label("All Companies", systemImage: selectedCompany == nil ? "checkmark" : "tray.full")
            }
            ForEach(companies, id: \.self) { company in
                Button { selectedCompany = company } label: {
                    Label(company, systemImage: selectedCompany == company ? "checkmark" : "building.2")
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
    }
}

private struct ActivityRow: View {
    let item: ActivityEntry

    private var title: String {
        item.contact.name.isEmpty ? item.contact.email : item.contact.name
    }

    /// The date label, with the time added for entries sent today.
    private var dateLabel: String {
        item.date?.activityLabelWithTime ?? "Sent"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(item.company)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(dateLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Image(systemName: "envelope.fill")
                .font(.title3)
                .foregroundStyle(.tint)
        }
    }
}

#Preview {
    ActivityView()
        .environment(JobStore())
}
