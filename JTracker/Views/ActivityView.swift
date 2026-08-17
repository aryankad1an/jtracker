import SwiftUI

/// The Activity tab: every cold mail you've sent, drawn as a vertical timeline.
///
/// The screen answers two questions at once. The summary card on top answers
/// "am I keeping up?" — a 14-day cadence chart, a streak, and three running
/// totals. The timeline below answers "what did I send, and to whom?" — days
/// become milestones on a rail, and each mail hangs off it as a card tinted with
/// its recipient's color (the same color their avatar gets everywhere else).
///
/// The company filter and the search field both narrow the timeline *and* the
/// summary above it, so filtering to one company shows that company's cadence
/// rather than a static all-time header.
struct ActivityView: View {
    @Environment(JobStore.self) private var jobStore

    @State private var summaryItem: ActivityEntry?
    @State private var selectedCompany: String?
    @State private var searchText = ""

    // MARK: - Derived data

    /// Entries for the current company filter + search, newest first (the store
    /// already hands them over in send order).
    private var visibleItems: [ActivityEntry] {
        jobStore.activity.filter { item in
            (selectedCompany == nil || item.company == selectedCompany) && matchesSearch(item)
        }
    }

    private func matchesSearch(_ item: ActivityEntry) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let fields = [item.contact.name, item.contact.email, item.contact.position,
                      item.company, item.contact.sentSubject ?? ""]
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Companies that have activity, most recently mailed first (the order they
    /// first appear in the newest-first feed), each with its send count.
    private var companyChips: [CompanyChip] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for item in jobStore.activity where !item.company.isEmpty {
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
            let key = item.date.map { calendar.startOfDay(for: $0) } ?? .distantPast
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
                } else if visibleItems.isEmpty {
                    ContentUnavailableView.search(text: searchText)
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
                    ActivitySummaryCard(items: visibleItems, scopeIsSingleCompany: selectedCompany != nil)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)

                    if !companyChips.isEmpty {
                        companyFilterRail
                            .padding(.bottom, 18)
                    }
                }

                ForEach(dayGroups) { group in
                    Section {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, item in
                            TimelineRow(
                                item: item,
                                // Fade the rail out under the very last card so the
                                // timeline ends rather than being cut off.
                                isTail: group.id == dayGroups.last?.id && index == group.entries.count - 1
                            ) {
                                summaryItem = item
                            }
                        }
                    } header: {
                        DayMilestoneHeader(day: group.id, count: group.entries.count)
                    }
                }
            }
            .padding(.top, 8)
        }
        .contentMargins(.bottom, 28, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await jobStore.load() }
        .animation(.snappy(duration: 0.28), value: selectedCompany)
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
                        color: .accentColor,
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
                withAnimation(.snappy(duration: 0.28)) {
                    proxy.scrollTo(company ?? Self.allChipID, anchor: .center)
                }
            }
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
                    .foregroundStyle(.secondary)
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

/// The card above the timeline: a 14-day bar chart of send volume, a streak
/// badge, and three totals. All of it is computed from the *filtered* entries, so
/// it re-reads as "this company's cadence" the moment a chip is tapped.
private struct ActivitySummaryCard: View {
    let items: [ActivityEntry]
    /// Drives the third tile: distinct companies normally, distinct people once
    /// the list is already narrowed to a single company.
    let scopeIsSingleCompany: Bool

    private static let barHeight: CGFloat = 56
    private static let window = 14

    private var sendDays: [Date] {
        let calendar = Calendar.current
        return items.compactMap(\.date).map { calendar.startOfDay(for: $0) }
    }

    /// One bucket per day for the last two weeks, oldest first.
    private var buckets: [DayBucket] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let counts = sendDays.reduce(into: [Date: Int]()) { $0[$1, default: 0] += 1 }
        return (0..<Self.window).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayBucket(id: day, count: counts[day] ?? 0)
        }
    }

    /// Consecutive days ending today with at least one send. A streak that last
    /// landed yesterday still counts — the day isn't over yet.
    private var streak: Int {
        let calendar = Calendar.current
        let days = Set(sendDays)
        guard !days.isEmpty else { return 0 }

        var cursor = calendar.startOfDay(for: .now)
        if !days.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  days.contains(yesterday) else { return 0 }
            cursor = yesterday
        }

        var length = 0
        while days.contains(cursor) {
            length += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return length
    }

    private var thisWeek: Int {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) else { return 0 }
        return items.filter { ($0.date ?? .distantPast) >= cutoff }.count
    }

    private var thirdTile: (value: Int, label: String) {
        if scopeIsSingleCompany {
            return (Set(items.map(\.contact.id)).count, "People")
        }
        return (Set(items.map(\.company).filter { !$0.isEmpty }).count, "Companies")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Last 14 days")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Spacer(minLength: 8)

                if streak >= 2 { streakBadge }
            }

            chart

            Divider().opacity(0.6)

            HStack(spacing: 0) {
                tile(items.count, "Sent")
                tileDivider
                tile(thisWeek, "This week")
                tileDivider
                tile(thirdTile.value, thirdTile.label)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.accentColor.opacity(0.16), .accentColor.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.tint.opacity(0.18), lineWidth: 1)
        }
    }

    private var streakBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .font(.caption2)
            Text("\(streak)-day streak")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.orange.opacity(0.14), in: Capsule())
    }

    private var chart: some View {
        let peak = max(buckets.map(\.count).max() ?? 0, 1)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(buckets) { bucket in
                VStack(spacing: 6) {
                    ZStack(alignment: .bottom) {
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                        if bucket.count > 0 {
                            Capsule()
                                .fill(Color.accentColor.gradient)
                                .opacity(bucket.id == today ? 1 : 0.55)
                                .frame(height: max(9, Self.barHeight * CGFloat(bucket.count) / CGFloat(peak)))
                        }
                    }
                    .frame(height: Self.barHeight)

                    Text(Self.weekdayInitial(for: bucket.id, calendar: calendar))
                        .font(.system(size: 9, weight: bucket.id == today ? .bold : .regular))
                        .foregroundStyle(bucket.id == today ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.snappy(duration: 0.3), value: buckets.map(\.count))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sends per day over the last 14 days")
        .accessibilityValue("\(items.count) total")
    }

    private static func weekdayInitial(for day: Date, calendar: Calendar) -> String {
        let index = calendar.component(.weekday, from: day) - 1
        let symbols = calendar.veryShortWeekdaySymbols
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    private func tile(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .contentTransition(.numericText())
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var tileDivider: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.6))
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
                        .fill(isSelected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(color.gradient))
                        .frame(width: 7, height: 7)
                }

                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .opacity(0.65)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background {
                if isSelected {
                    Capsule().fill(color.gradient)
                } else {
                    Capsule().fill(Color(.secondarySystemBackground))
                }
            }
            .overlay {
                Capsule().strokeBorder(isSelected ? .clear : Color(.separator).opacity(0.7), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.22), value: isSelected)
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
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color(.secondarySystemBackground)))
                .overlay(Capsule().strokeBorder(Color(.separator).opacity(0.8), lineWidth: 1))

            Text(count == 1 ? "1 mail" : "\(count) mails")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Timeline.gutter)
        .padding(.vertical, 10)
        // The rail runs through the header and disappears behind the capsule.
        .background(alignment: .topLeading) {
            Rectangle()
                .fill(Color(.separator))
                .frame(width: Timeline.railWidth)
                .frame(maxHeight: .infinity)
                .offset(x: Timeline.railCenter - Timeline.railWidth / 2)
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Timeline row

/// One sent mail: the recipient's avatar threaded onto the rail, and a card
/// tinted with their color carrying the name, role, time, and the subject line
/// that actually went out.
private struct TimelineRow: View {
    let item: ActivityEntry
    /// The last card in the whole timeline — its rail segment fades to nothing.
    let isTail: Bool
    let action: () -> Void

    private var title: String {
        item.contact.name.isEmpty ? item.contact.email : item.contact.name
    }

    private var accent: Color { .monogram(for: title) }

    private var subtitle: String {
        let parts = [item.contact.position, item.company].filter { !$0.isEmpty }
        return parts.isEmpty ? item.contact.email : parts.joined(separator: " · ")
    }

    private var timeLabel: String {
        guard let date = item.date else { return "—" }
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

    private var rail: some View {
        Rectangle()
            .fill(isTail
                  ? AnyShapeStyle(LinearGradient(colors: [Color(.separator), .clear],
                                                 startPoint: .top, endPoint: .bottom))
                  : AnyShapeStyle(Color(.separator)))
            .frame(width: Timeline.railWidth)
            .frame(maxHeight: .infinity)
            .offset(x: Timeline.railCenter - Timeline.railWidth / 2)
    }

    /// The avatar sits on the rail with a background-colored ring punched around
    /// it, so the line reads as passing behind rather than into it.
    private var avatar: some View {
        MonogramAvatar(text: title, size: Timeline.avatar)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Color.statusDone, in: Circle())
                    .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
            .background {
                Circle()
                    .fill(Color(.systemBackground))
                    .padding(-3)
            }
            .padding(.top, 6)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(timeLabel)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let subject = item.contact.sentSubject, !subject.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(accent.opacity(0.7))
                        .padding(.top, 2)
                    Text(subject)
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(accent.opacity(0.09))
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accent.opacity(0.16), lineWidth: 1)
        }
        .padding(.vertical, 6)
    }
}

/// A press treatment for the whole row — the card and its avatar dip together,
/// which a plain button style wouldn't do across the rail background.
private struct TimelineRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1, anchor: .leading)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

#Preview {
    ActivityView()
        .environment(JobStore())
}
