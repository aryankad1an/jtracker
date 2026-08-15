import SwiftUI

/// The Home tab: a dashboard of companies (from the database) under a collapsing
/// large title.
struct HomeView: View {
    @Environment(JobStore.self) private var jobStore

    @State private var isPickingCompany = false
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var confirmingDelete = false
    /// Companies removed in the last action, kept briefly so the Undo bar can
    /// restore them. Cleared after a few seconds or once Undo is tapped.
    @State private var undoJobs: [Job] = []
    @State private var undoTask: Task<Void, Never>?

    @ViewBuilder
    private func jobRows(_ jobs: [Job]) -> some View {
        ForEach(jobs) { job in
            NavigationLink {
                JobDetailView(jobID: job.id)
            } label: {
                CompanyRow(job: job)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    remove([job])
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if jobStore.jobs.isEmpty {
                    if jobStore.isLoading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    List(selection: $selection) {
                        Section { jobRows(jobStore.jobs) }
                    }
                    .listStyle(.plain)
                    .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
                    .refreshable { await jobStore.load() }
                }
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if isSelecting {
                        GlassDoneButton { exitSelection() }
                    } else {
                        Menu {
                            Button {
                                isPickingCompany = true
                            } label: {
                                Label("Add Company", systemImage: "plus")
                            }
                            if !jobStore.jobs.isEmpty {
                                Button {
                                    enterSelection()
                                } label: {
                                    Label("Select", systemImage: "checkmark.circle")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
            }
            .selectionActions(
                isSelecting: isSelecting,
                count: selection.count,
                noun: SelectionNoun(singular: "company", plural: "companies"),
                confirmingDelete: $confirmingDelete,
                confirmsDelete: false
            ) { deleteSelected() }
            .safeAreaInset(edge: .bottom) {
                if !undoJobs.isEmpty { undoBar }
            }
            .sheet(isPresented: $isPickingCompany) {
                CompanyPickerView(
                    companies: jobStore.availableCompanies,
                    isLoading: jobStore.isCatalogLoading,
                    onPick: { company in
                        Task { await jobStore.addCatalogCompany(company) }
                    },
                    onAddCustom: { name in
                        Task { await jobStore.addCustomCompany(name: name) }
                    }
                )
                .task { await jobStore.loadCatalog() }
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

    private func deleteSelected() {
        let toDelete = jobStore.jobs.filter { selection.contains($0.id) }
        exitSelection()
        remove(toDelete)
    }

    /// Remove companies from Home right away and offer a brief Undo. Untracking is
    /// reversible (it doesn't touch the shared database), so no confirmation.
    private func remove(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        for job in jobs { jobStore.deleteJob(job) }
        withAnimation { undoJobs = jobs }
        scheduleUndoDismiss()
    }

    private func undo() {
        undoTask?.cancel()
        for job in undoJobs { jobStore.restoreJob(job) }
        withAnimation { undoJobs = [] }
    }

    /// Auto-dismiss the Undo bar after 3 seconds.
    private func scheduleUndoDismiss() {
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation { undoJobs = [] } }
        }
    }

    private var undoBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text(undoJobs.count == 1
                 ? "Removed \(undoJobs[0].company)"
                 : "Removed \(undoJobs.count) companies")
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo") { undo() }
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Companies Yet", systemImage: "briefcase.fill")
        } description: {
            Text("Add a company to start tracking cold mails.")
        } actions: {
            Button {
                isPickingCompany = true
            } label: {
                Label("Add Company", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// A company row: a colored building avatar, the name, and an outreach summary.
private struct CompanyRow: View {
    let job: Job

    private var summary: String {
        let count = job.contacts.count
        guard count > 0 else { return "No entries yet" }
        return "\(count) contact\(count == 1 ? "" : "s")"
    }

    var body: some View {
        HStack(spacing: 14) {
            MonogramAvatar(text: job.company, systemImage: "building.2.fill")

            VStack(alignment: .leading, spacing: 3) {
                Text(job.company)
                    .font(.headline)
                    .lineLimit(1)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    HomeView()
        .environment(JobStore())
}
