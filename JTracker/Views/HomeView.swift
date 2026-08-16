import SwiftUI

/// The Home tab, focused on outreach you're tracking. It leads with a compact
/// "Suggested" widget (tap to open a drawer of companies you can cold-mail) and is
/// followed by the companies you track (swipe to untrack).
struct HomeView: View {
    @Environment(JobStore.self) private var jobStore

    @State private var showingSuggested = false
    /// Drives navigation to a tracked company's detail. Tracking rows are plain
    /// `Button`s (not `NavigationLink`) so a tap can be routed the same way the
    /// Suggested row is, keeping both rows' styling identical.
    @State private var path = NavigationPath()
    /// Companies removed in the last action, kept briefly so the Undo bar can
    /// restore them. Cleared after a few seconds or once Undo is tapped.
    @State private var undoJobs: [Job] = []
    @State private var undoTask: Task<Void, Never>?

    private var suggestedCount: Int { jobStore.suggestedContacts.count }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if jobStore.isLoading && jobStore.jobs.isEmpty && suggestedCount == 0 {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // A plain List so every row — Suggested included — gets the
                    // exact same system-drawn section card and insets. The
                    // Suggested row used to paint its own rounded card on top of
                    // that system card, which is what made its edges not line up
                    // with the plain Tracking rows below it.
                    List {
                        Section {
                            Button {
                                showingSuggested = true
                            } label: {
                                SuggestedRow(count: suggestedCount)
                            }
                            .buttonStyle(.plain)
                        }
                        trackingSection
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await jobStore.load() }
                }
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: String.self) { companyID in
                JobDetailView(jobID: companyID)
            }
            .safeAreaInset(edge: .bottom) {
                if !undoJobs.isEmpty { undoBar }
            }
            .sheet(isPresented: $showingSuggested) {
                SuggestedDrawer()
            }
        }
    }

    // MARK: - Tracking

    @ViewBuilder
    private var trackingSection: some View {
        Section {
            if jobStore.jobs.isEmpty {
                Text("No tracked companies yet. Track companies from the Companies tab.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(jobStore.jobs) { job in
                    Button {
                        path.append(job.id)
                    } label: {
                        TrackingRow(job: job)
                    }
                    .buttonStyle(.plain)
                    // Untrack is reachable from either swipe direction.
                    .swipeActions(edge: .trailing) { untrackButton(job) }
                    .swipeActions(edge: .leading) { untrackButton(job) }
                }
            }
        } header: {
            Text("Tracking")
                .textCase(nil)
                .font(.headline)
                .foregroundStyle(.primary)
        }
    }

    private func untrackButton(_ job: Job) -> some View {
        Button(role: .destructive) {
            remove([job])
        } label: {
            Label("Untrack", systemImage: "pin.slash")
        }
    }

    // MARK: - Untrack + Undo

    /// Untrack companies right away and offer a brief Undo. Untracking is
    /// reversible (it doesn't touch the shared catalog), so there's no confirm.
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
            Image(systemName: "pin.slash")
                .foregroundStyle(.secondary)
            Text(undoJobs.count == 1
                 ? "Untracked \(undoJobs[0].company)"
                 : "Untracked \(undoJobs.count) companies")
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
}

/// The Suggested entry row: styled exactly like `TrackingRow` (icon in place of
/// the monogram) so it's just another row in the same system section card, not a
/// competing card of its own. Tap opens the Suggested drawer.
private struct SuggestedRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.headline)
                .foregroundStyle(.tint)
                .frame(width: Theme.Avatar.medium, height: Theme.Avatar.medium)
                .background(.tint.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Suggested")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(count == 0 ? "All caught up" : "\(count) to reach out")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// A tracked-company row: a colored building avatar, the name, a contact count
/// summary, and a chevron (drawn manually, since this is a plain `Button` rather
/// than a `NavigationLink`, to keep its width identical to the Suggested widget).
private struct TrackingRow: View {
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
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    HomeView()
        .environment(JobStore())
}
