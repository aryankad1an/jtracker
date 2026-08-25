import SwiftUI

/// The Activity tab: every cold mail you've sent, drawn as a vertical timeline.
///
/// The screen answers two questions at once. The summary card on top answers
/// "am I keeping up?" — a cadence chart and three running
/// totals. The timeline below answers "what did I send, and to whom?" — days
/// become milestones on a rail, and each mail hangs off it as a card tinted with
/// its recipient's color (the same color their avatar gets everywhere else).
///
/// The company filter, the reply filter and the search field all narrow the
/// timeline *and* the summary above it, so filtering to one company shows that
/// company's cadence rather than a static all-time header.
struct ActivityView: View {
    @Environment(JobStore.self) private var jobStore
    /// Activity is where a user goes *looking* for an answer, so it owns a way to
    /// ask Gmail for one rather than waiting on the launch/foreground sync.
    @Environment(ReplySync.self) private var replySync

    /// Which mails to show. Replies are the reason to come back to this screen
    /// after the first day, so they get a filter of their own rather than being
    /// something you scroll to find.
    enum Lane: Hashable { case all, replied, waiting }

    @State private var summaryItem: ActivityEntry?
    @State private var selectedCompany: String?
    @State private var lane: Lane = .all
    @State private var searchText = ""

    // MARK: - Derived data

    /// The date this lane is a timeline *of*.
    ///
    /// Everywhere else that's the send date, but the Replied lane is a list of
    /// answers, and an answer's place in time is when it arrived — not when the
    /// mail that prompted it went out. Ordering that lane by send date put a
    /// reply that landed this morning below one that landed a fortnight ago,
    /// purely because the older thread had been started later.
    private func timelineDate(_ item: ActivityEntry) -> Date? {
        lane == .replied ? (item.contact.repliedAt ?? item.date) : item.date
    }

    /// Entries for the current company filter + search, newest first by whichever
    /// date this lane runs on.
    private var visibleItems: [ActivityEntry] {
        let matching = jobStore.activity.filter { item in
            (selectedCompany == nil || item.company == selectedCompany)
                && matchesLane(item)
                && matchesSearch(item)
        }
        // The store hands these over in send order, which is already right for
        // every lane but Replied.
        guard lane == .replied else { return matching }
        return matching.sorted { a, b in
            (timelineDate(a) ?? .distantPast) > (timelineDate(b) ?? .distantPast)
        }
    }

    /// Drop a company filter that the new lane has no rows for, so switching to
    /// Replied while filtered to a silent company doesn't show an empty screen
    /// with a chip selected that isn't on the rail any more.
    private func pruneCompanyFilter() {
        guard let selectedCompany else { return }
        if !companyChips.contains(where: { $0.id == selectedCompany }) {
            self.selectedCompany = nil
        }
    }

    private func matchesLane(_ item: ActivityEntry) -> Bool {
        switch lane {
        case .all: return true
        case .replied: return item.contact.hasReplied
        case .waiting: return !item.contact.hasReplied
        }
    }

    private func matchesSearch(_ item: ActivityEntry) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let fields = [item.contact.name, item.contact.email, item.contact.position,
                      item.company, item.contact.sentSubject ?? ""]
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Companies that have activity in the *current lane*, most recently mailed
    /// first (the order they first appear in the newest-first feed), each with its
    /// send count.
    ///
    /// Counted after the lane filter, before the company filter: counting the
    /// whole feed made a chip read "Even 3" above a single visible row once the
    /// Replied lane was on, and counting after the company filter would leave
    /// every chip but the chosen one reading zero.
    private var companyChips: [CompanyChip] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        let scope = jobStore.activity.filter { matchesLane($0) && matchesSearch($0) }
        for item in scope where !item.company.isEmpty {
            if counts[item.company] == nil { order.append(item.company) }
            counts[item.company, default: 0] += 1
        }
        return order.map { CompanyChip(id: $0, count: counts[$0] ?? 0) }
    }

    /// `visibleItems` cut into day sections, newest day first. Entries whose send
    /// date wasn't recorded collect in a trailing "Earlier" group.
    private var dayGroups: [DayGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [ActivityEntry]] = [:]
        for item in visibleItems {
            let key = timelineDate(item).map { calendar.startOfDay(for: $0) } ?? .distantPast
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(item)
        }
        return order.map { DayGroup(id: $0, entries: byDay[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if jobStore.activity.isEmpty {
                    emptyState
                } else {
                    timeline
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search people, companies, subjects")
            .sheet(item: $summaryItem) { item in
                MailSummaryView(contact: item.contact, company: item.company)
            }
        }
    }

    // MARK: - Timeline

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    // Dropped when the filter matches nothing: the card summarises
                    // the rows below it, and summarising none of them is a blank
                    // chart over three zeroes — a screenful of furniture between
                    // the title and the sentence explaining why the list is empty.
                    if !visibleItems.isEmpty {
                        ActivitySummaryCard(items: visibleItems, scopeIsSingleCompany: selectedCompany != nil)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                            // The header keeps its motion, and only the header
                            // does. The chart bars and the totals are small,
                            // fixed-position things, and watching them re-settle
                            // is what says the summary is describing the lane you
                            // just picked.
                            .animation(Theme.Motion.snappy, value: lane)
                            .animation(Theme.Motion.snappy, value: selectedCompany)
                    }

                    ReplyCheckStrip(sync: replySync) { Task { await checkForReplies() } }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)

                    SegmentedSelector(segments: [
                        (.all, "All", "tray.full"),
                        (.replied, "Replied", "arrowshape.turn.up.left.fill"),
                        (.waiting, "Waiting", "hourglass")
                    ], selection: $lane)
                        .onChange(of: lane) { pruneCompanyFilter() }
                        .padding(.horizontal, 16)
                        .padding(.bottom, companyChips.isEmpty ? 18 : 12)

                    if !companyChips.isEmpty {
                        companyFilterRail
                            .padding(.bottom, 18)
                            .animation(Theme.Motion.snappy, value: lane)
                    }
                }

                if visibleItems.isEmpty {
                    laneEmptyState
                        .stillOnFilterChange()
                }

                ForEach(dayGroups) { group in
                    Section {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, item in
                            TimelineRow(
                                item: item,
                                timestamp: timelineDate(item),
                                isReplyOrdered: lane == .replied,
                                // Fade the rail out under the very last card so the
                                // timeline ends rather than being cut off.
                                isTail: group.id == dayGroups.last?.id && index == group.entries.count - 1
                            ) {
                                summaryItem = item
                            }
                            .stillOnFilterChange()
                        }
                    } header: {
                        DayMilestoneHeader(day: group.id, count: group.entries.count)
                            .stillOnFilterChange()
                    }
                }
            }
            .padding(.top, 8)
        }
        .background(Color.paper)
        .contentMargins(.bottom, 28, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)
        // A pull here means "is there anything new?", and the answer to that lives
        // in Gmail, not in the database — reloading alone would only ever re-read
        // the replies a previous sync had already written.
        .refreshable { await checkForReplies() }
    }

    /// Ask Gmail what came back, then reload. `syncReplies` reloads by itself only
    /// when the sync found something, so the plain reload covers a pull that was
    /// really about a send made on another device.
    private func checkForReplies() async {
        await jobStore.load()
        await jobStore.syncReplies(using: replySync)
    }

    /// Shown in place of the rows when the current lane, company or search has
    /// nothing in it. Inline rather than replacing the screen: the filters that
    /// emptied the list have to stay on screen, or the only way back out of an
    /// empty lane is to leave the tab.
    @ViewBuilder
    private var laneEmptyState: some View {
        Group {
            if !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ContentUnavailableView(
                    lane == .replied ? "No replies yet" : "Nothing waiting",
                    systemImage: lane == .replied ? "tray" : "checkmark.circle",
                    description: Text(lane == .replied
                        ? "Answers appear here as soon as they land in Gmail."
                        : "Every mail in this view has been answered.")
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    // MARK: - Company filter

    /// A horizontal ribbon of company chips, ordered by how recently you mailed
    /// them. Replaces the old toolbar menu: the same filter, but you can see the
    /// options and their volumes without opening anything.
    private var companyFilterRail: some View {
        // The reader keeps the active chip on screen: the rail is longer than the
        // display, so without this the chip you just picked (or one restored from a
        // previous filter) can sit past the edge, leaving no visible sign of what
        // the timeline is currently narrowed to.
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    FilterChip(
                        title: "All",
                        count: jobStore.activity.count,
                        color: .clay,
                        systemImage: "tray.full.fill",
                        isSelected: selectedCompany == nil
                    ) {
                        selectedCompany = nil
                    }
                    .id(Self.allChipID)

                    ForEach(companyChips) { chip in
                        FilterChip(
                            title: chip.id,
                            count: chip.count,
                            color: .monogram(for: chip.id),
                            systemImage: nil,
                            isSelected: selectedCompany == chip.id
                        ) {
                            selectedCompany = selectedCompany == chip.id ? nil : chip.id
                        }
                        .id(chip.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .onChange(of: selectedCompany) { _, company in
                // Snappy, not bouncy: a spring with real overshoot applied to a
                // scroll offset reads as the rail rebounding off its own edge.
                withAnimation(Theme.Motion.snappy) {
                    proxy.scrollTo(company ?? Self.allChipID, anchor: .center)
                }
            }
            // On the value rather than in each chip, so the rail also clicks when
            // a filter is dropped because its lane no longer has rows for it.
            .sensoryFeedback(.selection, trigger: selectedCompany)
        }
    }

    /// Identity for the leading "All" chip, which has no company name of its own.
    private static let allChipID = "\u{0}all"

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.12))
                    .frame(width: 104, height: 104)
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.tint)
                    .rotationEffect(.degrees(-14))
            }

            VStack(spacing: 6) {
                Text("No mail sent yet")
                    .font(.title3.weight(.semibold))
                Text("Every cold mail you send lands here — newest first, with the exact subject and message that went out.")
                    .font(.subheadline)
                    .foregroundStyle(.inkMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Layout constants

/// Geometry shared by the rows and the day headers so the rail, the avatars, and
/// the milestone chips all line up on the same vertical axis.
private enum Timeline {
    static let gutter: CGFloat = 16
    static let avatar: CGFloat = 40
    static let railWidth: CGFloat = 1.5
    /// Distance from the screen's leading edge to the center of the rail — the
    /// avatars sit centered on it like beads on a string.
    static var railCenter: CGFloat { gutter + avatar / 2 }
}

// MARK: - Motion

private extension View {
    /// Opts a timeline row out of whatever animation a filter change arrived
    /// under.
    ///
    /// Switching lane replaces most of a lazy list at once. Animated, the springs
    /// overlapped: rows that survived the cut travelled the height of the screen
    /// to reach their new slot, the pinned day headers slid along with them, and
    /// rows the `LazyVStack` had not built yet arrived mid-flight. A filter is a
    /// question about what is already there, so the answer should simply be there.
    ///
    /// It has to be a transaction rather than dropping the `.animation` modifiers
    /// that used to sit on the scroll view: the segmented control wraps its own
    /// selection change in a spring, and that spring propagates down the whole
    /// tree from above. Applied per row (not to an enclosing `Group`) so each
    /// `Section` stays a direct child of the `LazyVStack` and keeps pinning its
    /// header.
    func stillOnFilterChange() -> some View {
        transaction { $0.animation = nil }
    }
}

// MARK: - Model helpers

private struct CompanyChip: Identifiable {
    let id: String   // company name
    let count: Int
}

private struct DayGroup: Identifiable {
    let id: Date     // start of day, or `.distantPast` for undated sends
    let entries: [ActivityEntry]
}

// MARK: - Summary card

/// The card above the timeline: a cadence chart of send volume and three totals.
/// All of it is computed from the *filtered* entries, so it re-reads as "this
/// company's cadence" the moment a company chip is tapped.
///
/// **The chart sizes its own window to the width it is given** — a fortnight on a
/// phone, up to two months on an iPad. It has to, because the alternative is what
/// this card used to do: draw exactly fourteen columns however much width it was
/// handed. On a tablet that made each "bar" a hundred points wide and fifty-eight
/// tall, and a capsule that much wider than it is tall isn't a bar any more, it's
/// a lozenge. Widening the window instead of the columns means the extra space
/// buys more history rather than fatter shapes.
private struct ActivitySummaryCard: View {
    let items: [ActivityEntry]
    /// Drives the third tile: distinct companies normally, distinct people once
    /// the list is already narrowed to a single company.
    let scopeIsSingleCompany: Bool

    /// The tallest a column can draw.
    private static let barHeight: CGFloat = 58
    /// The widest a single day may get, and the gap between days. The cap is the
    /// whole fix: it's what keeps a column reading as a column at any width.
    private static let maxBarWidth: CGFloat = 20
    private static let barSpacing: CGFloat = 6
    /// The window, in days. A fortnight is the floor (below that the chart stops
    /// showing a rhythm and starts showing a handful of days); two months is the
    /// ceiling, past which a day is too thin to aim at or read.
    private static let minDays = 14
    private static let maxDays = 60
    /// Fixed so the chart can be measured for width without its height depending
    /// on what that measurement returns.
    private static let chartHeight: CGFloat = 94
    /// Above this many columns, per-day weekday initials stop being a legend and
    /// become a smear, so the axis switches to naming the range's two ends.
    private static let weekdayLabelLimit = 16

    private var sendDays: [Date] {
        let calendar = Calendar.current
        return items.compactMap(\.date).map { calendar.startOfDay(for: $0) }
    }

    /// How many days fit at a readable column width.
    private static func days(forWidth width: CGFloat) -> Int {
        guard width > 0 else { return minDays }
        let slot = maxBarWidth + barSpacing
        return min(maxDays, max(minDays, Int(width / slot)))
    }

    /// One bucket per day in the window, oldest first.
    private func buckets(days: Int) -> [DayBucket] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let counts = sendDays.reduce(into: [Date: Int]()) { $0[$1, default: 0] += 1 }
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayBucket(id: day, count: counts[day] ?? 0)
        }
    }

    private var replyCount: Int {
        items.filter(\.contact.hasReplied).count
    }

    private var thirdTile: (value: Int, label: String) {
        if scopeIsSingleCompany {
            return (Set(items.map(\.contact.id)).count, "People")
        }
        return (Set(items.map(\.company).filter { !$0.isEmpty }).count, "Companies")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cadence")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.inkMuted)
                .textCase(.uppercase)
                .tracking(0.6)

            // Width in, day count out — a pure function of the measurement, so
            // there's no state to settle and no first-render flicker from 14
            // columns to 60.
            GeometryReader { geometry in
                chart(buckets(days: Self.days(forWidth: geometry.size.width)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: Self.chartHeight)

            Divider().opacity(0.6)

            HStack(spacing: 0) {
                tile(items.count, "Sent")
                tileDivider
                tile(replyCount, "Replied", tint: replyCount > 0 ? .statusDone : nil)
                tileDivider
                tile(thirdTile.value, thirdTile.label)
            }
        }
        .padding(16)
        .panel(radius: Theme.Radius.hero)
    }

    // MARK: - Chart

    @ViewBuilder
    private func chart(_ buckets: [DayBucket]) -> some View {
        let peak = max(buckets.map(\.count).max() ?? 0, 1)
        // The most recent day at the peak, so a tie labels the one nearest today
        // rather than the one furthest from it.
        let peakDay = buckets.last { $0.count == peak }?.id
        let today = Calendar.current.startOfDay(for: .now)
        let showsWeekdays = buckets.count <= Self.weekdayLabelLimit

        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: Self.barSpacing) {
                ForEach(buckets) { bucket in
                    column(bucket, peak: peak, peakDay: peakDay,
                           today: today, showsWeekday: showsWeekdays)
                }
            }

            // Past the weekday limit the columns lose their letters, so the axis
            // states the range instead — otherwise a two-month chart is a wall of
            // unreadable initials that says nothing about when any of it was.
            if !showsWeekdays, let first = buckets.first?.id {
                HStack(spacing: 0) {
                    Text(first.formatted(.dateTime.month(.abbreviated).day()))
                    Spacer(minLength: 8)
                    Text("Today")
                }
                .font(.system(size: 9))
                .foregroundStyle(.inkFaint)
            }
        }
        .animation(Theme.Motion.settle, value: buckets.map(\.count))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sends per day over the last \(buckets.count) days")
        .accessibilityValue("\(items.count) total, busiest day \(peak)")
    }

    /// One day.
    private func column(_ bucket: DayBucket, peak: Int, peakDay: Date?,
                        today: Date, showsWeekday: Bool) -> some View {
        let isToday = bucket.id == today
        let isPeak = bucket.id == peakDay && peak > 1
        let height = bucket.count == 0
            ? 0
            : max(7, Self.barHeight * CGFloat(bucket.count) / CGFloat(peak))

        return VStack(spacing: 4) {
            // The busiest day wears its own number. Without it the chart has no
            // scale at all — the tallest bar could mean two mails or two hundred,
            // and every bar below it is a fraction of an unknown.
            Text(isPeak ? "\(peak)" : "0")
                .font(.system(size: 9, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.clay)
                .opacity(isPeak ? 1 : 0)
                // The column is capped at `maxBarWidth` so the bars stay bars,
                // and the label inherited that cap: a busy day peaking in three
                // figures came out as "1…", which is worse than no scale at all
                // because it looks like a number. Fixed at its ideal width it
                // overflows into the gaps instead, and the only column that draws
                // one is the peak, so there is nothing there to overlap.
                .lineLimit(1)
                .fixedSize()

            ZStack(alignment: .bottom) {
                // Deliberately no track. A full-height grey capsule behind every
                // day drew fourteen loud empty shapes to carry three quiet full
                // ones, so the chart's strongest marks were the days nothing
                // happened on.
                Color.clear

                if bucket.count > 0 {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isToday ? Color.clay : Color.clay.opacity(0.5))
                        .frame(height: height)
                } else {
                    // A quiet day is a dot on the baseline: absence stays legible
                    // without competing with the days that have something to say.
                    Circle()
                        .fill(Color.hairline)
                        .frame(width: 3, height: 3)
                }
            }
            .frame(height: Self.barHeight)

            if showsWeekday {
                Text(Self.weekdayInitial(for: bucket.id))
                    .font(.system(size: 9, weight: isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? AnyShapeStyle(Color.clay) : AnyShapeStyle(.tertiary))
            }
        }
        // The ceiling that keeps a column a column.
        .frame(maxWidth: Self.maxBarWidth)
    }

    private static func weekdayInitial(for day: Date) -> String {
        let calendar = Calendar.current
        let index = calendar.component(.weekday, from: day) - 1
        let symbols = calendar.veryShortWeekdaySymbols
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    private func tile(_ value: Int, _ label: String, tint: Color? = nil) -> some View {
        Metric(value: value, caption: label, tint: tint ?? .primary, size: 22)
    }

    private var tileDivider: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(width: 1, height: 26)
    }
}
private struct DayBucket: Identifiable {
    let id: Date
    let count: Int
}

// MARK: - Filter chip

private struct FilterChip: View {
    let title: String
    let count: Int
    let color: Color
    let systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2)
                } else {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                }

                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .opacity(0.65)
            }
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 12)
            .frame(height: 34)
            // The active chip lifts into glass; the rest stay flat paper. Filling
            // it with the company's own colour (the previous treatment) made the
            // filter louder than the timeline it filters, and put a different loud
            // colour on screen depending on which company happened to be chosen.
            .background {
                if isSelected {
                    Color.clear.glassEffect(.regular.tint(Color.clay.opacity(0.14)).interactive(),
                                            in: .capsule)
                } else {
                    Capsule().fill(Color.paperRaised)
                        .overlay { Capsule().strokeBorder(Color.hairline, lineWidth: 1) }
                }
            }
        }
        // The chip is a small control, so it dips further than a card would and
        // knocks on the way down.
        .buttonStyle(BouncyPress(scale: 0.93))
        .animation(Theme.Motion.pop, value: isSelected)
        .animation(Theme.Motion.pop, value: count)
        // The selected chip sits slightly proud of the rail, so the active filter
        // is findable by shape as well as by material.
        .scaleEffect(isSelected ? 1.04 : 1)
    }
}

// MARK: - Day milestone header

/// A pinned day marker. Its opaque background interrupts the rail, so each day
/// reads as a milestone the timeline passes through rather than a list header.
private struct DayMilestoneHeader: View {
    let day: Date
    let count: Int

    private var label: String {
        day == .distantPast ? "Earlier" : day.activityLabel
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .tracking(0.7)
                .foregroundStyle(.inkMuted)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.paperRaised))
                .overlay(Capsule().strokeBorder(Color.hairline.opacity(0.8), lineWidth: 1))

            Text(count == 1 ? "1 mail" : "\(count) mails")
                .font(.caption2)
                .foregroundStyle(.inkFaint)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Timeline.gutter)
        .padding(.vertical, 10)
        // The rail runs through the header and disappears behind the capsule.
        .background(alignment: .topLeading) {
            Rectangle()
                .fill(Color.hairline)
                .frame(width: Timeline.railWidth)
                .frame(maxHeight: .infinity)
                .offset(x: Timeline.railCenter - Timeline.railWidth / 2)
        }
        .background(Color.paper)
    }
}

// MARK: - Timeline row

/// One sent mail: the recipient's avatar threaded onto the rail, and a card
/// tinted with their color carrying the name, role, time, and the subject line
/// that actually went out.
private struct TimelineRow: View {
    let item: ActivityEntry
    /// The moment this row is filed under — the send, or the reply in the lane
    /// that runs on reply time. Shown in the corner, and it's the date the day
    /// header above the row was cut from.
    let timestamp: Date?
    /// Whether the row sits on the timeline by its reply rather than by its send.
    /// It changes what the row has left to tell you: filed under the answer, the
    /// useful second date is when the mail that earned it went out.
    let isReplyOrdered: Bool
    /// The last card in the whole timeline — its rail segment fades to nothing.
    let isTail: Bool
    let action: () -> Void

    private var title: String {
        item.contact.name.isEmpty ? item.contact.email : item.contact.name
    }


    private var subtitle: String {
        let parts = [item.contact.position, item.company].filter { !$0.isEmpty }
        return parts.isEmpty ? item.contact.email : parts.joined(separator: " · ")
    }

    private var timeLabel: String {
        guard let date = timestamp else { return "—" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                avatar
                card
            }
            .padding(.horizontal, Timeline.gutter)
            .background(alignment: .topLeading) { rail }
            .contentShape(Rectangle())
        }
        .buttonStyle(TimelineRowStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the mail that was sent")
    }

    /// What came back, quoted under the mail that prompted it. Set apart by a
    /// leading rule rather than another card, so the reply reads as attached to
    /// this send rather than as a second event on the timeline.
    private var replyNote: some View {
        HStack(alignment: .top, spacing: 7) {
            Capsule()
                .fill(Color.statusDone)
                .frame(width: 2.5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    // The glyph follows the words: a turned arrow when the line
                    // names the reply, a paperplane when it names the send.
                    Image(systemName: isReplyOrdered ? "paperplane.fill" : "arrowshape.turn.up.left.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text(replyNoteTitle)
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.statusDone)

                if let snippet = item.contact.replySnippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.caption2)
                        .foregroundStyle(.inkMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .padding(.top, 3)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The line above the quoted snippet. Filed under the send, it names the
    /// reply; filed under the reply, naming it again would only repeat the day
    /// header and the corner time, so it names the send instead and the row
    /// carries both ends of the exchange.
    private var replyNoteTitle: String {
        if isReplyOrdered {
            return item.contact.sentAt.map { "Sent \($0.activityLabel)" } ?? "Replied"
        }
        return item.contact.repliedAt.map { "Replied \($0.activityLabel)" } ?? "Replied"
    }

    private var rail: some View {
        Rectangle()
            .fill(isTail
                  ? AnyShapeStyle(LinearGradient(colors: [Color.hairline, .clear],
                                                 startPoint: .top, endPoint: .bottom))
                  : AnyShapeStyle(Color.hairline))
            .frame(width: Timeline.railWidth)
            .frame(maxHeight: .infinity)
            .offset(x: Timeline.railCenter - Timeline.railWidth / 2)
    }

    private var hasReplied: Bool { item.contact.hasReplied }

    /// The avatar sits on the rail with a background-colored ring punched around
    /// it, so the line reads as passing behind rather than into it. Its badge is
    /// the row's state in one glyph: a paperplane for sent, and a turned arrow
    /// once they've written back.
    private var avatar: some View {
        MonogramAvatar(text: title, size: Timeline.avatar)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: hasReplied ? "arrowshape.turn.up.left.fill" : "paperplane.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(hasReplied ? Color.statusDone : Color.secondary, in: Circle())
                    .overlay(Circle().strokeBorder(Color.paper, lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
            .background {
                Circle()
                    .fill(Color.paper)
                    .padding(-3)
            }
            .padding(.top, 6)
            // The badge flips from paperplane to turned-arrow the moment a sync
            // finds the answer, and springs as it does.
            .animation(Theme.Motion.pop, value: hasReplied)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ink)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(timeLabel)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.inkMuted)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.inkMuted)
                .lineLimit(1)

            if let subject = item.contact.sentSubject, !subject.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.inkFaint)
                        .padding(.top, 2)
                    Text(subject)
                        .font(.caption)
                        .foregroundStyle(Color.ink.opacity(0.75))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.top, 1)
            }

            if hasReplied { replyNote }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The card is plain paper; only a reply earns a rule. Tinting every card
        // with its recipient's colour made a scroll through the timeline read as
        // a colour chart rather than as a sequence of events.
        .panelAccented(hasReplied ? .statusDone : nil)
        .padding(.vertical, 6)
    }
}

/// A press treatment for the whole row — the card and its avatar dip together,
/// which a plain button style wouldn't do across the rail background.
private struct TimelineRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            // Anchored leading, so the card dips toward the rail it hangs off
            // rather than shrinking away from it in both directions.
            .scaleEffect(configuration.isPressed ? 0.975 : 1, anchor: .leading)
            .animation(Theme.Motion.pop, value: configuration.isPressed)
            .sensoryFeedback(trigger: configuration.isPressed) { _, pressed in
                pressed ? .impact(weight: .light, intensity: 0.55) : nil
            }
    }
}

// MARK: - Reply check

/// The one line on Activity that says whether the reply column can be trusted:
/// when Gmail was last read, whether a read is running, and — when replies can't
/// be read at all — why.
///
/// Activity has this because it is where an unanswered mail is looked at. The
/// launch-and-foreground sync in `RootView` covers the common case, but a user
/// watching for one specific answer needs a way to ask now, and a way to find out
/// that the answer was never going to arrive because the token predates the
/// mail-reading scope.
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
                .buttonStyle(.glass)
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
