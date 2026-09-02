import SwiftUI

/// The Home tab: what came back, then what you're tracking.
///
/// It opens on the Quick Actions card — the campaign scored in one glance,
/// tapping through to the follow-up, reply and reach-out lanes — because the
/// first question on opening the app is "did anyone answer?", not "which
/// companies am I tracking?". The tracked companies follow, each carrying its
/// own reply/waiting state so the answer to that first question is legible
/// without leaving the screen.
///
/// Rows are `List` rows with cleared backgrounds rather than a `ScrollView` of
/// cards, so swipe-to-untrack keeps working while the cards get their own shape.
struct HomeView: View {
    @Environment(JobStore.self) private var jobStore
    @Environment(ReplySync.self) private var replySync

    @State private var showingQuickActions = false
    /// Drives navigation to a tracked company's detail. Rows are plain `Button`s
    /// (not `NavigationLink`) so the card fills the row without the system's
    /// chevron and inset.
    @State private var path = NavigationPath()
    /// Companies removed in the last action, kept briefly so the Undo bar can
    /// restore them. Cleared after a few seconds or once Undo is tapped.
    @State private var undoJobs: [Job] = []
    @State private var undoTask: Task<Void, Never>?
    @State private var searchText = ""

    private var insights: Insights { jobStore.insights }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !query.isEmpty }

    /// Tracked companies narrowed by the search field. A company matches on its own
    /// name or sector *and* on the people inside it: Home is where you go to find
    /// the company you mailed someone at, and by then the name you remember is
    /// often theirs rather than the company's.
    private var filteredJobs: [Job] {
        guard isSearching else { return jobStore.jobs }
        return jobStore.jobs.filter { $0.matches(query) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if jobStore.isLoading && jobStore.jobs.isEmpty && insights.totalSent == 0 {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        // Hidden while searching: the card is a summary of
                        // everything, which is the opposite of what a query asked
                        // for, and it would push the first result off the screen.
                        if !isSearching {
                            Section {
                                Button { showingQuickActions = true } label: {
                                    QuickActionsCard(insights: insights, isSyncing: replySync.isSyncing)
                                }
                                .cardButtonStyle()
                                .listRowInsets(EdgeInsets(top: 6, leading: Theme.Space.gutter,
                                                          bottom: 10, trailing: Theme.Space.gutter))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }

                        trackingSection
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.paper)
                    .refreshable { await jobStore.load() }
                    .scrollDismissesKeyboard(.immediately)
                    // Rows springing in and out is the whole feedback for tracking
                    // and untracking — the list is where the change lands.
                    .animation(Theme.Motion.bouncy, value: jobStore.jobs.map(\.id))
                    // Typing re-cuts the list on every keystroke, and a spring per
                    // character turns a search into a shuffle. The rows just change.
                    .animation(nil, value: query)
                    .overlay {
                        if isSearching && filteredJobs.isEmpty {
                            ContentUnavailableView.search(text: query)
                                .background(Color.paper)
                        }
                    }
                }
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search tracked companies and people")
            .navigationDestination(for: String.self) { companyID in
                JobDetailView(jobID: companyID)
            }
            .safeAreaInset(edge: .bottom) {
                if !undoJobs.isEmpty { undoBar }
            }
            .sheet(isPresented: $showingQuickActions) {
                QuickActionsView()
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
                    .foregroundStyle(.inkMuted)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(filteredJobs) { job in
                    Button {
                        path.append(job.id)
                    } label: {
                        TrackingCard(job: job)
                    }
                    .cardButtonStyle()
                    .listRowInsets(EdgeInsets(top: 4, leading: Theme.Space.gutter,
                                              bottom: 4, trailing: Theme.Space.gutter))
                    // Untrack is reachable from either swipe direction.
                    .swipeActions(edge: .trailing) { untrackButton(job) }
                    .swipeActions(edge: .leading) { untrackButton(job) }
                }
            }
        } header: {
            SectionLabel(title: "Tracking", systemImage: "pin.fill",
                         count: jobStore.jobs.isEmpty ? nil : filteredJobs.count)
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.bottom, 2)
                .listRowInsets(EdgeInsets())
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
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
        // The flat knock, not the light one: this is the destructive edge of the
        // swipe, and it should feel unlike selecting the row it just removed.
        Haptics.thud()
        for job in jobs { jobStore.deleteJob(job) }
        withAnimation(Theme.Motion.bouncy) { undoJobs = jobs }
        scheduleUndoDismiss()
    }

    private func undo() {
        undoTask?.cancel()
        Haptics.success()
        for job in undoJobs { jobStore.restoreJob(job) }
        withAnimation(Theme.Motion.bouncy) { undoJobs = [] }
    }

    private func scheduleUndoDismiss() {
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            // Silent on the way out. The bar timing out isn't something the user
            // did, and a knock here would read as a second thing happening.
            withAnimation(Theme.Motion.bouncy) { undoJobs = [] }
        }
    }

    private var undoBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "pin.slash")
                .foregroundStyle(.inkMuted)
            Text(undoJobs.count == 1
                 ? "Untracked \(undoJobs[0].company)"
                 : "Untracked \(undoJobs.count) companies")
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            // A custom button style drops the accent tint the default one paints,
            // so the colour is restated here — Undo has to keep reading as the
            // one tappable word in the bar.
            Button("Undo") { undo() }
                .font(.subheadline.weight(.semibold))
                .bouncyButtonStyle()
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal)
        .padding(.bottom, 8)
        // Scaled as well as moved: the capsule grows into place from just under
        // the edge rather than sliding up at full size, which is what makes it
        // read as a thing that arrived rather than a thing that was always there.
        .transition(.move(edge: .bottom)
            .combined(with: .scale(scale: 0.9, anchor: .bottom))
            .combined(with: .opacity))
    }
}

// MARK: - Quick Actions card

/// Home's headline: the reply rate as a ring, with the two counts that decide
/// what to do next. Tapping opens Quick Actions, where those counts become
/// lists you can tick and send.
private struct QuickActionsCard: View {
    let insights: Insights
    let isSyncing: Bool

    @State private var ring: Double = 0

    private var subtitle: String {
        if insights.totalSent == 0 { return "Send your first mail to start tracking" }
        if let longest = insights.longestSilenceDays, longest > 0 {
            let waiting = insights.waitingMails.count
            return "Longest silence \(longest)d · \(waiting) awaiting a reply"
        }
        return "\(insights.totalSent) mails tracked"
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.hairline, lineWidth: 7)
                Circle()
                    .trim(from: 0, to: max(ring, 0.001))
                    .stroke(
                        Color.olive,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text("\(Int((insights.replyRate * 100).rounded()))%")
                    .font(.display(16, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Quick Actions")
                        .font(.display(19))
                        .foregroundStyle(.ink)
                    if isSyncing {
                        ProgressView().controlSize(.mini)
                    }
                }

                HStack(spacing: 8) {
                    countChip(insights.totalReplies, "replied", .statusDone)
                    countChip(insights.waitingMails.count, "waiting", .statusWaiting)
                }

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.inkFaint)
        }
        .padding(14)
        .panel(radius: Theme.Radius.hero)
        .task(id: insights.replyRate) {
            withAnimation(Theme.Motion.settle) { ring = insights.replyRate }
        }
    }

    private func countChip(_ value: Int, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(.footnote.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
        .animation(Theme.Motion.pop, value: value)
    }
}

// MARK: - Tracking card

/// A tracked company, carrying its own outreach state: how many people, how many
/// answered, and how long the rest have been quiet.
private struct TrackingCard: View {
    let job: Job

    private var replied: Int { job.repliedContacts.count }
    private var awaiting: Int { job.awaitingContacts.count }

    /// Days since the most recent mail to anyone here.
    private var silence: Int? {
        guard awaiting > 0,
              let last = job.awaitingContacts.compactMap(\.sentAt).max() else { return nil }
        return Calendar.current.dateComponents([.day], from: last, to: .now).day
    }

    private var accent: Color { .monogram(for: job.company) }

    var body: some View {
        HStack(spacing: 12) {
            MonogramAvatar(text: job.company, systemImage: "building.2.fill")

            // The chips sit on their own line rather than trailing the contact
            // count. Chips are intrinsically sized so they can't shrink, and on a
            // narrow phone a count plus two of them ran past the card's edge.
            VStack(alignment: .leading, spacing: 5) {
                Text(job.company)
                    .font(.headline)
                    .foregroundStyle(.ink)
                    .lineLimit(1)

                Text(job.contacts.isEmpty
                     ? "No contacts yet"
                     : "\(job.contacts.count) contact\(job.contacts.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)

                if replied > 0 || silence != nil {
                    HStack(spacing: 6) {
                        if replied > 0 {
                            StatusChip(text: "\(replied) replied",
                                       systemImage: "arrowshape.turn.up.left.fill",
                                       color: .statusDone)
                        }
                        if let silence {
                            StatusChip(text: silence == 0 ? "Sent today" : "\(silence)d quiet",
                                       systemImage: "hourglass",
                                       color: .statusWaiting)
                        }
                    }
                    .padding(.top, 1)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.inkFaint)
        }
        .padding(12)
        .panel()
    }
}

#Preview {
    HomeView()
        .environment(JobStore())
        .environment(ReplySync())
}
