import SwiftUI

/// The Companies tab: the full shared catalog. This is where companies are added,
/// edited, deleted (all upstream, for every user), and tracked onto your Home.
/// By default only companies with at least one contact are shown; a "Show empty"
/// toggle reveals the rest.
struct CompaniesView: View {
    @Environment(JobStore.self) private var jobStore

    @State private var searchText = ""
    @State private var showEmpty = false
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var confirmingDelete = false
    @State private var pendingDelete: Job?
    @State private var isAdding = false
    @State private var editingCompany: Job?

    /// Companies to show: catalog filtered by the "show empty" toggle and the
    /// search text (name or sector). Already name-sorted by the store.
    private var filtered: [Job] {
        var list = jobStore.allCompanies
        if !showEmpty { list = list.filter { !$0.contacts.isEmpty } }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter {
                $0.company.localizedCaseInsensitiveContains(query) ||
                ($0.sector?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                if jobStore.allCompanies.isEmpty {
                    if jobStore.isLoading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if filtered.isEmpty {
                    noMatchesState.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selection) {
                        Section { companyRows(filtered) }
                    }
                    .listStyle(.plain)
                    .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
                    .refreshable { await jobStore.load() }
                }
            }
            .navigationTitle("Companies")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search companies")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if isSelecting {
                        GlassDoneButton { exitSelection() }
                    } else {
                        menu
                    }
                }
            }
            .selectionActions(
                isSelecting: isSelecting,
                count: selection.count,
                noun: SelectionNoun(singular: "company", plural: "companies"),
                confirmingDelete: $confirmingDelete,
                deleteMessage: "This permanently deletes the selected companies — and their contacts — from the shared database, for every user. This can't be undone.",
                bulkAction: trackAction
            ) { deleteSelected() }
            .confirmationDialog(
                "Delete \(pendingDelete?.company ?? "company")?",
                isPresented: Binding(get: { pendingDelete != nil },
                                     set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let job = pendingDelete { Task { await jobStore.deleteCompanyUpstream(job.id) } }
                    pendingDelete = nil
                }
            } message: {
                Text("This permanently deletes this company and its contacts from the shared database, for every user. This can't be undone.")
            }
            .sheet(isPresented: $isAdding) {
                CompanyFormView(title: "New Company", confirmLabel: "Add") { name, sector in
                    // A brand-new company has no contacts yet, so reveal empty
                    // companies — otherwise the add would seem to do nothing.
                    showEmpty = true
                    Task { await jobStore.createCompany(name: name, sector: sector.isEmpty ? nil : sector) }
                }
            }
            .sheet(item: $editingCompany) { company in
                CompanyFormView(name: company.company, sector: company.sector ?? "",
                                title: "Edit Company", confirmLabel: "Save") { name, sector in
                    Task { await jobStore.updateCompany(id: company.id, name: name,
                                                        sector: sector.isEmpty ? nil : sector) }
                }
            }
        }
    }

    private var menu: some View {
        Menu {
            Button { isAdding = true } label: {
                Label("Add Company", systemImage: "plus")
            }
            if !jobStore.allCompanies.isEmpty {
                Button { enterSelection() } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
            }
            Divider()
            Toggle(isOn: $showEmpty) {
                Label("Show empty companies", systemImage: "tray")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More actions")
    }

    @ViewBuilder
    private func companyRows(_ companies: [Job]) -> some View {
        ForEach(companies) { company in
            let tracked = jobStore.isTracked(company.id)
            NavigationLink {
                JobDetailView(jobID: company.id)
            } label: {
                CompanyRow(job: company, isTracked: tracked)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    pendingDelete = company
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading) {
                // Track/Untrack is declared first so a full ("extreme") swipe
                // triggers it; Edit sits behind it.
                if tracked {
                    Button {
                        jobStore.untrack(companyID: company.id)
                    } label: {
                        Label("Untrack", systemImage: "pin.slash")
                    }
                    .tint(.gray)
                } else {
                    Button {
                        jobStore.track(companyID: company.id)
                    } label: {
                        Label("Track", systemImage: "pin")
                    }
                    .tint(.green)
                }
                Button {
                    editingCompany = company
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.blue)
            }
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

    /// One slot that flips meaning: once everything selected is already tracked,
    /// "Track" is a no-op, so the button becomes the useful inverse instead of
    /// leaving tracked companies with no bulk action at all.
    private var trackAction: SelectionBulkAction {
        let selected = jobStore.allCompanies.filter { selection.contains($0.id) }
        let allTracked = !selected.isEmpty && selected.allSatisfy { jobStore.isTracked($0.id) }
        return SelectionBulkAction(
            title: allTracked ? "Untrack" : "Track",
            systemImage: allTracked ? "pin.slash.fill" : "pin.fill"
        ) {
            if allTracked {
                for company in selected { jobStore.untrack(companyID: company.id) }
            } else {
                jobStore.trackCompanies(Array(selection))
            }
            exitSelection()
        }
    }

    private func deleteSelected() {
        let ids = Array(selection)
        exitSelection()
        Task { for id in ids { await jobStore.deleteCompanyUpstream(id) } }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Companies Yet", systemImage: "building.2")
        } description: {
            Text("Add a company to the shared catalog.")
        } actions: {
            Button {
                isAdding = true
            } label: {
                Label("Add Company", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var noMatchesState: some View {
        ContentUnavailableView {
            Label("No Companies", systemImage: "magnifyingglass")
        } description: {
            Text(showEmpty
                 ? "No companies match your search."
                 : "No companies with contacts. Turn on “Show empty companies” to see the rest.")
        }
    }
}

/// A company row in the Companies list: monogram, name, an optional sector, a pin
/// when tracked, and a fixed-size contacts-count pill that never truncates.
private struct CompanyRow: View {
    let job: Job
    let isTracked: Bool

    var body: some View {
        HStack(spacing: 14) {
            MonogramAvatar(text: job.company, systemImage: "building.2.fill")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(job.company)
                        .font(.headline)
                        .lineLimit(1)
                    if isTracked {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                }
                if let sector = job.sector, !sector.isEmpty {
                    Text(sector)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            countPill
        }
        .padding(.vertical, 4)
    }

    /// The contact count as a compact capsule. `fixedSize` keeps it at its
    /// intrinsic width so it can never be squeezed or overflow — the name
    /// truncates instead.
    private var countPill: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.2.fill")
            Text("\(job.contacts.count)")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.secondary.opacity(0.15), in: Capsule())
        .fixedSize()
    }
}
