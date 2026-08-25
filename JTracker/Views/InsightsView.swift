import SwiftUI

/// Insights: what came back from everything you've sent.
///
/// The screen is built around the one question a cold-mail tracker exists to
/// answer — *who owes me a reply, and for how long?* — so silence is treated as
/// data rather than as an absence. The hero panel scores the whole campaign, and
/// three lanes below cut the same history three ways: who's gone quiet longest,
/// who answered, and who hasn't been contacted yet.
///
/// It replaces the old "Suggested" drawer, which only ever knew about the last
/// of those three.
struct InsightsView: View {
    @Environment(JobStore.self) private var jobStore
    @Environment(ReplySync.self) private var replySync
    @Environment(\.dismiss) private var dismiss

    enum Lane: Hashable { case waiting, replied, reachOut }

    @State private var lane: Lane = .waiting
    @State private var summaryItem: ActivityEntry?
    @State private var sendBatch: SendBatch?
    @State private var path = NavigationPath()

    private var insights: Insights { jobStore.insights }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 22) {
                    HeroPanel(insights: insights, sync: replySync) {
                        Task { await sync() }
                    }

                    if !bouncedContacts.isEmpty { bounceBanner }

                    SegmentedSelector(segments: [
                        (.waiting, "Waiting", "hourglass"),
                        (.replied, "Replied", "arrowshape.turn.up.left.fill"),
                        (.reachOut, "New", "sparkles")
                    ], selection: $lane)

                    lanes
                        // Lanes swap in place, so the incoming set springs up from
                        // slightly below and slightly small — the same arrival the
                        // rest of the app uses for a thing appearing.
                        .transition(.scale(scale: 0.96, anchor: .top)
                            .combined(with: .offset(y: 10))
                            .combined(with: .opacity))
                }
                .animation(Theme.Motion.bouncy, value: lane)
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.bottom, 32)
                .padding(.top, 4)
            }
            .background(Color.paper)
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: String.self) { companyID in
                JobDetailView(jobID: companyID)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await sync() }
            // A check that actually found something is the one moment this screen
            // changes on its own, so it gets the double-tap "arrived" knock. A
            // check that found nothing stays silent rather than claiming news —
            // this fires on the sync finishing, not on the count being non-zero,
            // so it can't re-announce the same replies on every refresh.
            .onChange(of: replySync.lastSyncedAt) { _, _ in
                if (replySync.lastOutcome?.replies ?? 0) > 0 { Haptics.arrival() }
            }
            .animation(Theme.Motion.bouncy, value: bouncedContacts.count)
            .sheet(item: $summaryItem) { item in
                MailSummaryView(contact: item.contact, company: item.company)
            }
            .sheet(item: $sendBatch) { batch in
                SuggestedSendView(recipients: batch.recipients)
            }
        }
    }

    // MARK: - Lanes

    @ViewBuilder
    private var lanes: some View {
        switch lane {
        case .waiting: waitingLane
        case .replied: repliedLane
        case .reachOut: reachOutLane
        }
    }

    /// Companies that have heard nothing back, longest silence first. The order is
    /// the whole point: the top of this list is the follow-up you should write
    /// today.
    @ViewBuilder
    private var waitingLane: some View {
        let stats = insights.waitingOn
        if stats.isEmpty {
            InlineEmptyState(
                title: insights.totalSent == 0 ? "Nothing sent yet" : "Everyone has answered",
                systemImage: insights.totalSent == 0 ? "paperplane" : "checkmark.seal.fill",
                message: insights.totalSent == 0
                    ? "Send your first cold mail and this fills in."
                    : "Every company you've mailed has replied at least once.",
                tint: insights.totalSent == 0 ? .secondary : .statusDone
            )
        } else {
            let longest = stats.first?.daysWaiting ?? 1
            VStack(spacing: 12) {
                SectionLabel(title: "Waiting on", systemImage: "hourglass",
                             count: stats.count, tint: .statusWaiting)
                ForEach(stats) { stat in
                    Button {
                        open(stat)
                    } label: {
                        WaitingCard(stat: stat, longestWait: longest)
                    }
                    .cardButtonStyle()
                }
            }
        }
    }

    /// Who wrote back, most recent first, each with the first line of what they
    /// actually said — a reply you can't read is just a badge.
    @ViewBuilder
    private var repliedLane: some View {
        if insights.replies.isEmpty {
            InlineEmptyState(
                title: "No replies yet",
                systemImage: "tray",
                message: "Answers show up here as soon as they land in Gmail.",
                tint: .statusDone
            )
        } else {
            VStack(spacing: 12) {
                SectionLabel(title: "Replied", systemImage: "arrowshape.turn.up.left.fill",
                             count: insights.repliedPeople, tint: .statusDone)
                ForEach(insights.replies) { entry in
                    Button { summaryItem = entry } label: {
                        ReplyCard(entry: entry)
                    }
                    .cardButtonStyle()
                }
            }
        }
    }

    /// The old Suggested list, kept as one lane of four: people who can still be
    /// mailed and haven't been in the last month.
    @ViewBuilder
    private var reachOutLane: some View {
        let groups = jobStore.suggestedGroups
        if groups.isEmpty {
            InlineEmptyState(
                title: "All caught up",
                systemImage: "checkmark.circle",
                message: "Everyone reachable has been mailed in the last month.",
                tint: .clay
            )
        } else {
            VStack(spacing: 12) {
                SectionLabel(title: "Ready to reach out", systemImage: "sparkles",
                             count: groups.reduce(0) { $0 + $1.contacts.count })
                ForEach(groups, id: \.company.id) { group in
                    Button {
                        sendBatch = SendBatch(recipients: group.contacts.map {
                            (contact: $0, company: group.company.company)
                        })
                    } label: {
                        ReachOutCard(company: group.company, contacts: group.contacts)
                    }
                    .cardButtonStyle()
                }
            }
        }
    }

    // MARK: - Bounces

    /// Contacts whose thread came back with a delivery failure. Surfaced here
    /// because the fix already exists — `is_valid` — and this is the only screen
    /// that knows the address is dead.
    private var bouncedContacts: [Contact] {
        let ids = replySync.bouncedRecruiterIDs
        guard !ids.isEmpty else { return [] }
        return jobStore.allCompanies
            .flatMap(\.contacts)
            .filter { ids.contains($0.id) && $0.isValid }
    }

    private var bounceBanner: some View {
        let contacts = bouncedContacts
        return HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.statusInvalid)

            VStack(alignment: .leading, spacing: 2) {
                Text(contacts.count == 1 ? "1 address bounced" : "\(contacts.count) addresses bounced")
                    .font(.subheadline.weight(.semibold))
                Text("Gmail couldn't deliver these. Mark them invalid to drop them from Suggested.")
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Mark") {
                Haptics.thud()
                Task { await jobStore.setValidity(contacts.map(\.id), isValid: false) }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .tint(.statusInvalid)
            .fixedSize()
        }
        .padding(14)
        .panel(accent: .statusInvalid)
        .popIn()
    }

    // MARK: - Actions

    private func open(_ stat: Insights.CompanyStat) {
        guard let id = stat.companyID else { return }
        path.append(id)
    }

    private func sync() async {
        await jobStore.syncReplies(using: replySync)
    }
}

private struct SendBatch: Identifiable {
    let id = UUID()
    let recipients: [(contact: Contact, company: String)]
}

// MARK: - Hero

/// The scoreboard: how much went out, how much came back, and how long the wait
/// typically is — plus the control for checking Gmail again.
private struct HeroPanel: View {
    let insights: Insights
    let sync: ReplySync
    let onSync: () -> Void

    private var syncLabel: String {
        if sync.isSyncing { return sync.progress.label }
        guard let last = sync.lastSyncedAt else { return "Not checked yet" }
        return "Checked \(last.activityLabelWithTime.lowercased())"
    }

    var body: some View {
        VStack(spacing: 18) {
            // The ring and the sentence that explains it share the top line; the
            // figures get a full-width row of their own underneath. Packed onto
            // one line beside the ring they had barely a third of the width each,
            // which is what made a three-digit send count feel cramped.
            HStack(alignment: .center, spacing: 18) {
                ReplyRing(rate: insights.replyRate, replies: insights.totalReplies)

                VStack(alignment: .leading, spacing: 6) {
                    Text(headline)
                        .font(.display(17))
                        .foregroundStyle(.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    if let fact { heroFact(fact.symbol, fact.text) }
                }

                Spacer(minLength: 0)
            }

            Divider().overlay(Color.hairline)

            HStack(spacing: 0) {
                Metric(value: insights.totalSent, caption: "Sent", size: 25)
                MetricDivider()
                Metric(value: insights.totalReplies, caption: "Replies",
                       tint: .statusDone, size: 25)
                MetricDivider()
                Metric(value: insights.unanswered.count, caption: "Waiting",
                       tint: .statusWaiting, size: 25)
            }

            Divider().overlay(Color.hairline)

            syncBar
        }
        .padding(18)
        .panel(radius: Theme.Radius.hero)
        // The bar grows a progress track while a check runs and drops it after,
        // which changes the panel's height — springing it keeps the cards below
        // from snapping into their new place.
        .animation(Theme.Motion.bouncy, value: sync.isSyncing)
    }

    /// One line saying how the campaign is going, in words rather than figures —
    /// so the numbers below are free to just be numbers.
    private var headline: String {
        guard insights.totalSent > 0 else { return "Nothing sent yet" }
        switch insights.repliedPeople {
        case 0: return "No replies yet"
        case 1: return "1 person has written back"
        default: return "\(insights.repliedPeople) people have written back"
        }
    }

    private var fact: (symbol: String, text: String)? {
        if let median = insights.medianResponseDays {
            return ("clock.arrow.circlepath",
                    median == 0 ? "Replies usually land same day" : "Replies usually land in \(median)d")
        }
        if let longest = insights.longestSilenceDays {
            return ("hourglass", "Longest silence \(longest)d")
        }
        return nil
    }

    private func heroFact(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2)
            Text(text)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(.inkMuted)
    }

    /// Something the user has to fix before replies can be read at all.
    private func blocker(_ symbol: String, _ message: String) -> some View {
        Label {
            Text(message)
                .font(.caption)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .font(.caption)
        }
        .foregroundStyle(.statusInvalid)
    }

    @ViewBuilder
    private var syncBar: some View {
        VStack(spacing: 8) {
            if sync.isSyncing && sync.progress.total > 0 {
                ProgressView(value: sync.progress.fraction)
                    .tint(.clay)
                    .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
            }

            HStack(spacing: 8) {
                if sync.needsMigration {
                    blocker("cylinder.split.1x2.fill",
                            "Database is missing the reply columns — run the migration in the README")
                } else if sync.needsReconnect {
                    blocker("lock.trianglebadge.exclamationmark.fill",
                            "Reconnect Gmail in Profile to read replies")
                } else {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.caption2)
                        .foregroundStyle(.inkMuted)
                        .symbolEffect(.rotate, isActive: sync.isSyncing)
                    Text(syncLabel)
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    Haptics.press()
                    onSync()
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
    }
}

/// The reply rate as a ring. A percentage in a row of numbers is just another
/// number; drawn as an arc it's the one thing on the panel with a shape, which is
/// what makes it the headline.
///
/// Drawn flat in the reply colour rather than in a gradient sweep: the ring is a
/// measurement, and a gradient would imply a scale it doesn't have.
private struct ReplyRing: View {
    let rate: Double
    let replies: Int

    @State private var shown: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.hairline, lineWidth: 9)

            Circle()
                .trim(from: 0, to: max(shown, 0.001))
                .stroke(
                    Color.olive,
                    style: StrokeStyle(lineWidth: 9, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: -1) {
                Text("\(Int((rate * 100).rounded()))%")
                    .font(.display(22, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("replied")
                    .font(.system(size: 9))
                    .foregroundStyle(.inkMuted)
            }
        }
        .frame(width: 86, height: 86)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reply rate")
        .accessibilityValue("\(Int((rate * 100).rounded())) percent, \(replies) replies")
        .task(id: rate) {
            withAnimation(Theme.Motion.settle) { shown = rate }
        }
    }
}

// MARK: - Cards

/// One waiting company. The bar underneath is a silence meter: it fills relative
/// to the longest wait on the list and warms as it goes, so the queue can be read
/// by shape alone before any of the numbers are.
private struct WaitingCard: View {
    let stat: Insights.CompanyStat
    let longestWait: Int

    private var days: Int { stat.daysWaiting ?? 0 }

    private var heat: Color {
        switch days {
        case ..<7: return .statusWaiting
        case ..<14: return .clay
        case ..<28: return .statusInvalid
        default: return .danger
        }
    }

    private var fill: Double {
        guard longestWait > 0 else { return 0 }
        return min(1, max(0.06, Double(days) / Double(longestWait)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                MonogramAvatar(text: stat.name, size: Theme.Avatar.small,
                               systemImage: "building.2.fill")

                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                    Text("\(stat.people) contacted · \(stat.sent) mail\(stat.sent == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(days)")
                        .font(.display(22, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(heat)
                    Text(days == 1 ? "day" : "days")
                        .font(.system(size: 9))
                        .foregroundStyle(.inkMuted)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.hairline)
                    Capsule()
                        .fill(heat)
                        .frame(width: geometry.size.width * fill)
                        // The meter fills from empty on each appearance, so the
                        // queue draws itself in front of you rather than arriving
                        // already drawn.
                        .animation(Theme.Motion.settle, value: fill)
                }
            }
            .frame(height: 5)
        }
        .padding(14)
        .panel(accent: heat)
    }
}

/// A reply, with the opening line of what they said.
private struct ReplyCard: View {
    let entry: ActivityEntry

    private var name: String {
        entry.contact.name.isEmpty ? entry.contact.email : entry.contact.name
    }

    /// Who actually answered. A reply from a different address than the one we
    /// mailed is the normal case for a shared inbox, so it's shown rather than
    /// quietly folded into the contact's name.
    private var replierNote: String? {
        guard let from = entry.contact.replyFrom, !from.isEmpty else { return nil }
        let address = Self.address(in: from)
        guard !address.isEmpty,
              address.caseInsensitiveCompare(entry.contact.email) != .orderedSame else { return nil }
        return address
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MonogramAvatar(text: name, size: Theme.Avatar.small)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 17, height: 17)
                        .background(Color.statusDone, in: Circle())
                        .overlay(Circle().strokeBorder(Color.paperRaised, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let replied = entry.contact.repliedAt {
                        Text(replied.activityLabel)
                            .font(.caption2)
                            .foregroundStyle(.statusDone)
                    }
                }

                Text(entry.company)
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)

                if let snippet = entry.contact.replySnippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(Color.ink.opacity(0.75))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 2)
                }

                if let replierNote {
                    Text("via \(replierNote)")
                        .font(.caption2)
                        .foregroundStyle(.inkFaint)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .panel(accent: .statusDone)
    }

    /// Pull the bare address out of a `Name <a@b.com>` header.
    private static func address(in header: String) -> String {
        guard let open = header.lastIndex(of: "<"), let close = header.lastIndex(of: ">"),
              open < close else {
            return header.trimmingCharacters(in: .whitespaces)
        }
        return String(header[header.index(after: open)..<close])
    }
}

/// A company with people who can still be mailed.
private struct ReachOutCard: View {
    let company: Job
    let contacts: [Contact]

    private var neverMailed: Int { contacts.filter { !$0.isSent }.count }

    private var reachOutSummary: String {
        if neverMailed == contacts.count { return "\(contacts.count) never contacted" }
        if neverMailed == 0 { return "\(contacts.count) due for a follow-up" }
        return "\(contacts.count) to reach out · \(neverMailed) new"
    }

    var body: some View {
        HStack(spacing: 12) {
            MonogramAvatar(text: company.company, size: Theme.Avatar.small,
                           systemImage: "building.2.fill")

            VStack(alignment: .leading, spacing: 2) {
                Text(company.company)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                Text(reachOutSummary)
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "paperplane.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.clay, in: Circle())
                // The plane takes off as the group's size changes — a company
                // gaining a reachable contact is the reason to look at this card.
                .symbolEffect(.bounce, value: contacts.count)
        }
        .padding(14)
        .panel()
    }
}

#Preview {
    InsightsView()
        .environment(JobStore())
        .environment(ReplySync())
}
