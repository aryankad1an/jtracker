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
    /// Rows push through this rather than through `NavigationLink`, so the card
    /// can carry its own chevron instead of the system drawing one outside it.
    @State private var path = NavigationPath()

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Companies to show: catalog filtered by the "show empty" toggle and the
    /// search text. Already name-sorted by the store.
    ///
    /// A search overrides "show empty": having typed a name, a company that
    /// matches it but has no contacts yet is a result, not a row to hide — and
    /// hiding it is indistinguishable from the company not existing, which is the
    /// question the search was asked to answer.
    private var filtered: [Job] {
        guard query.isEmpty else { return jobStore.allCompanies.filter { $0.matches(query) } }
        return showEmpty ? jobStore.allCompanies : jobStore.allCompanies.filter { !$0.contacts.isEmpty }
    }

    var body: some View {
        NavigationStack(path: $path) {
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
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: Theme.Space.gutter,
                                                      bottom: 4, trailing: Theme.Space.gutter))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.paper)
                    .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
                    .refreshable { await jobStore.load() }
                    // Companies added, deleted, or filtered out spring rather than
                    // cut, so the catalog changing is visible without a banner.
                    .animation(Theme.Motion.bouncy, value: filtered.map(\.id))
                    // Each row's pin appears and disappears with the same spring.
                    .animation(Theme.Motion.pop, value: jobStore.jobs.count)
                    // ...but not while typing: springing the list once per
                    // keystroke makes a search read as a shuffle.
                    .animation(nil, value: query)
                    .scrollDismissesKeyboard(.immediately)
                }
            }
            .navigationTitle("Companies")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: String.self) { companyID in
                JobDetailView(jobID: companyID)
            }
            .searchable(text: $searchText, prompt: "Search companies, sectors, people")
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
            CompanyRow(job: company, isTracked: tracked)
                .selectableRow(isSelecting: isSelecting) {
                    beginSelection(with: company.id)
                } onTap: {
                    path.append(company.id)
                }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    // A warning, not a knock: this swipe opens a dialog that
                    // deletes for every user, and it should feel like a stop.
                    Haptics.warning()
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
                        Haptics.tap()
                        jobStore.untrack(companyID: company.id)
                    } label: {
                        Label("Untrack", systemImage: "pin.slash")
                    }
                    .tint(.slate)
                } else {
                    Button {
                        // Pinning something to Home is the one constructive swipe
                        // on this screen, so it lands firmer than untracking does.
                        Haptics.press()
                        jobStore.track(companyID: company.id)
                    } label: {
                        Label("Track", systemImage: "pin")
                    }
                    .tint(.olive)
                }
                Button {
                    Haptics.tap()
                    editingCompany = company
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.clay)
            }
        }
    }

    private func enterSelection() {
        selection = []
        Haptics.press()
        withAnimation(Theme.Motion.bouncy) { isSelecting = true }
    }

    /// Entered by holding a row: the mode arrives with that row already picked,
    /// which is the whole reason to hold *this* row rather than any other. The
    /// knock is played by `SelectionHold`, so there's none here.
    private func beginSelection(with id: String) {
        selection = [id]
        withAnimation(Theme.Motion.bouncy) { isSelecting = true }
    }

    private func exitSelection() {
        Haptics.tap(0.5)
        withAnimation(Theme.Motion.bouncy) { isSelecting = false }
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
                Haptics.tap()
            } else {
                jobStore.trackCompanies(Array(selection))
                // One beat per company, capped — a bulk track should feel like
                // more than a single one did.
                Haptics.cascade(selection.count)
            }
            exitSelection()
        }
    }

    private func deleteSelected() {
        let ids = Array(selection)
        Haptics.thud()
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
            Text(query.isEmpty
                 ? "No companies with contacts. Turn on “Show empty companies” to see the rest."
                 : "No company, sector or contact matches “\(query)”.")
        }
    }
}

/// A company card in the Companies list: monogram, name, an optional sector, a
/// pin when tracked, and a fixed-size contacts-count pill that never truncates.
/// A reply chip appears once anyone here has written back, so the catalog carries
/// the same outreach state Home and Quick Actions do.
private struct CompanyRow: View {
    let job: Job
    let isTracked: Bool

    private var replied: Int { job.repliedContacts.count }

    var body: some View {
        HStack(spacing: 12) {
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
                            // The pin springs in the moment a swipe tracks the
                            // company, on the row the swipe happened on.
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                    }
                }
                if let sector = job.sector, !sector.isEmpty {
                    Text(sector)
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                        .lineLimit(1)
                }
                // Own line, for the same reason as Home's card: a long sector name
                // beside a fixed-width chip overflowed the row on a narrow phone.
                if replied > 0 {
                    StatusChip(text: "\(replied) replied",
                               systemImage: "arrowshape.turn.up.left.fill",
                               color: .statusDone)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 8)

            countPill

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.inkFaint)
        }
        .padding(12)
        .panel()
        .animation(Theme.Motion.pop, value: isTracked)
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
        .foregroundStyle(.inkMuted)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.secondary.opacity(0.15), in: Capsule())
        .fixedSize()
    }
}
