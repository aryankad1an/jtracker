import SwiftUI

/// The Activity tab: every mail you've sent, hung off a time axis and grouped by
/// day, newest first.
///
/// Lanes (All · Replied · Waiting) and search narrow the feed; the strip above
/// says when Gmail was last read for replies and asks it again on demand.
struct ActivityView: View {
    @Environment(JobStore.self) private var jobStore
    /// Activity is where a user goes *looking* for an answer, so it owns a way to
    /// ask Gmail for one rather than waiting on the launch/foreground sync.
    @Environment(ReplySync.self) private var replySync

    enum Lane: Hashable { case all, replied, waiting }

    @State private var lane: Lane = .all
    @State private var searchText = ""
    @State private var summaryItem: ActivityEntry?

    var body: some View {
        NavigationStack {
            Group {
                if jobStore.activity.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .paperScreen()
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search people, companies, subjects")
            .sheet(item: $summaryItem) { item in
                MailSummaryView(contact: item.contact, company: item.company)
            }
        }
    }

    private var content: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ReplyCheckStrip(sync: replySync) { Task { await checkForReplies() } }
                    .padding(.horizontal, 4)

                SegmentedSelector(segments: [
                    (.all, "All", "tray.full"),
                    (.replied, "Replied", "arrowshape.turn.up.left.fill"),
                    (.waiting, "Waiting", "hourglass")
                ], selection: $lane)

                ActivityFeed(entries: Self.feed(jobStore.activity, lane: lane, query: query),
                             isReplyOrdered: lane == .replied) { summaryItem = $0 }
                    // A new filter is a new feed: back to its first page.
                    .id("\(lane)|\(query)")
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.immediately)
        // A pull here means "is there anything new?", and the answer to that lives
        // in Gmail, not in the database.
        .refreshable { await checkForReplies() }
    }

    /// The entries in `lane` matching `query`. The store's order is newest send
    /// first — right for every lane but Replied, which is a list of answers and
    /// runs on when they arrived.
    private static func feed(_ entries: [ActivityEntry], lane: Lane, query: String) -> [ActivityEntry] {
        let matching = entries.filter { entry in
            switch lane {
            case .all: break
            case .replied: guard entry.contact.hasReplied else { return false }
            case .waiting: guard !entry.contact.hasReplied else { return false }
            }
            guard !query.isEmpty else { return true }
            return entry.company.localizedCaseInsensitiveContains(query)
                || entry.contact.matches(query)
                || (entry.contact.sentSubject?.localizedCaseInsensitiveContains(query) ?? false)
        }
        guard lane == .replied else { return matching }
        return matching.sorted {
            ($0.contact.repliedAt ?? $0.date ?? .distantPast) > ($1.contact.repliedAt ?? $1.date ?? .distantPast)
        }
    }

    /// Ask Gmail what came back, then reload.
    private func checkForReplies() async {
        await jobStore.load()
        await jobStore.syncReplies(using: replySync, forceFullCheck: true)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No mail sent yet", systemImage: "paperplane")
        } description: {
            Text("Every mail you send lands here — newest first, with the exact subject and message that went out.")
        }
    }
}

// MARK: - The feed

/// The mails, hung off a time axis and grouped by day. Built 50 at a time: the
/// next page is attached when the end of the current one scrolls into view.
private struct ActivityFeed: View {
    let entries: [ActivityEntry]
    let isReplyOrdered: Bool
    let onOpen: (ActivityEntry) -> Void

    @State private var limit = 50

    var body: some View {
        let shown = entries.prefix(limit)
        if entries.isEmpty {
            InlineEmptyState(title: "Nothing here", systemImage: "line.3.horizontal.decrease",
                             message: "No mail matches this lane and filter.")
        } else {
            ForEach(Self.days(shown, isReplyOrdered: isReplyOrdered), id: \.day) { group in
                FeedDayHeader(day: group.day, count: group.entries.count)
                ForEach(group.entries) { entry in
                    FeedRow(entry: entry, isReplyOrdered: isReplyOrdered) { onOpen(entry) }
                }
            }
            if entries.count > limit {
                LoadingRow()
                    .onAppear { limit += 50 }
            }
        }
    }

    private static func days(_ entries: ArraySlice<ActivityEntry>,
                             isReplyOrdered: Bool) -> [(day: Date, entries: [ActivityEntry])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [ActivityEntry]] = [:]
        for entry in entries {
            let date = isReplyOrdered ? (entry.contact.repliedAt ?? entry.date) : entry.date
            let key = date.map { calendar.startOfDay(for: $0) } ?? .distantPast
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(entry)
        }
        return order.map { ($0, byDay[$0] ?? []) }
    }
}

/// Geometry shared by the header and the rows, so the axis runs through both.
private enum FeedAxis {
    static let timeWidth: CGFloat = 52
    static let spacing: CGFloat = 10
    static let node: CGFloat = 10
    static var center: CGFloat { timeWidth + spacing + node / 2 }
}

/// A day on the axis: a label, a dashed rule, a count — like a chart's tick.
private struct FeedDayHeader: View {
    let day: Date
    let count: Int

    private var label: String {
        if day == .distantPast { return "Earlier" }
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(.inkMuted)
            Rectangle()
                .fill(Color.hairline)
                .frame(height: 1)
                .mask(HStack(spacing: 3) {
                    ForEach(0..<60, id: \.self) { _ in Rectangle().frame(width: 3) }
                })
            Text("\(count)")
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(.inkFaint)
        }
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
    }
}

/// One mail: its time, a node on the axis, and a card with who, where, what.
private struct FeedRow: View {
    let entry: ActivityEntry
    let isReplyOrdered: Bool
    let action: () -> Void

    private var hasReplied: Bool { entry.contact.hasReplied }

    private var time: Date? {
        isReplyOrdered ? (entry.contact.repliedAt ?? entry.date) : entry.date
    }

    private var subtitle: String {
        let parts = [entry.contact.position, entry.company].filter { !$0.isEmpty }
        return parts.isEmpty ? entry.contact.email : parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: FeedAxis.spacing) {
                Text(time?.formatted(date: .omitted, time: .shortened) ?? "—")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.inkFaint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: FeedAxis.timeWidth, alignment: .trailing)
                    .padding(.top, 14)

                Circle()
                    .fill(hasReplied ? Color.olive : Color.clay)
                    .frame(width: FeedAxis.node, height: FeedAxis.node)
                    .overlay(Circle().strokeBorder(Color.paper, lineWidth: 2))
                    .padding(.top, 16)

                card
            }
            .background(alignment: .topLeading) {
                // The axis the nodes sit on.
                Rectangle()
                    .fill(Color.hairline)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .offset(x: FeedAxis.center - 0.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(CardPress())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the mail that was sent")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(entry.contact.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if hasReplied { RepliedPill(at: entry.contact.repliedAt) }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.inkMuted)
                .lineLimit(1)
            if let subject = entry.contact.sentSubject, !subject.isEmpty {
                Text(subject)
                    .font(.caption)
                    .foregroundStyle(Color.ink.opacity(0.8))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if hasReplied, let snippet = entry.contact.replySnippet, !snippet.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Capsule().fill(Color.olive).frame(width: 2.5)
                    Text(snippet)
                        .font(.caption2)
                        .foregroundStyle(.inkMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelAccented(hasReplied ? .olive : nil)
        .padding(.vertical, 4)
    }
}

// MARK: - Reply check

/// The one line on Activity that says whether the reply column can be trusted:
/// when Gmail was last read, whether a read is running, and — when replies can't
/// be read at all — why.
private struct ReplyCheckStrip: View {
    let sync: ReplySync
    let onCheck: () -> Void

    /// The blocking reason replies can't be read, if there is one. Both are things
    /// only the user can fix, so both are stated rather than retried.
    private var blocker: (symbol: String, message: String)? {
        if sync.needsMigration {
            return ("cylinder.split.1x2.fill",
                    "Database is missing the reply columns — run the migration in the README")
        }
        if sync.needsReconnect {
            return ("lock.trianglebadge.exclamationmark.fill",
                    "Reconnect Gmail in Profile to read replies")
        }
        return nil
    }

    private var label: String {
        if sync.isSyncing { return sync.progress.label.isEmpty ? "Checking Gmail…" : sync.progress.label }
        guard let last = sync.lastSyncedAt else { return "Replies not checked yet" }
        return "Checked \(last.activityLabelWithTime.lowercased())"
    }

    var body: some View {
        VStack(spacing: 8) {
            if sync.isSyncing && sync.progress.total > 0 {
                ProgressView(value: sync.progress.fraction)
                    .tint(.clay)
            }

            HStack(spacing: 8) {
                if let blocker {
                    Label {
                        Text(blocker.message)
                            .font(.caption)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: blocker.symbol).font(.caption)
                    }
                    .foregroundStyle(.statusInvalid)
                } else {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.caption2)
                        .foregroundStyle(.inkMuted)
                        .symbolEffect(.rotate, isActive: sync.isSyncing)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    Haptics.press()
                    onCheck()
                } label: {
                    Text(sync.isSyncing ? "Checking…" : "Check now")
                        .font(.caption.weight(.semibold))
                }
                .secondaryButton()
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(sync.isSyncing)
            }
        }
        .animation(Theme.Motion.snappy, value: sync.isSyncing)
    }
}

#Preview {
    ActivityView()
        .environment(JobStore())
        .environment(ReplySync())
}
