import SwiftUI

/// The send queue's presence in the UI: a compact strip that rides above the tab
/// bar while mails go out, and reports the result when they're done.
///
/// It lives in the tab bar's accessory slot — the same shelf a music app uses for
/// its mini player — because that's the one place in iOS that means "something of
/// yours is still running" without covering the screen you're using. Sending is
/// no longer something you wait on, so it shouldn't own a screen.
struct SendQueueBar: View {
    @Environment(MailQueue.self) private var queue

    /// How long a clean result stays up before clearing itself. Failures don't
    /// auto-clear — those need to be read.
    private static let successLinger = Duration.seconds(5)

    var body: some View {
        HStack(spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            trailingControl
        }
        .padding(.horizontal, 14)
        .task(id: queue.outcome?.failed.isEmpty) {
            // Only a fully successful run clears itself.
            guard let outcome = queue.outcome, outcome.failed.isEmpty else { return }
            try? await Task.sleep(for: Self.successLinger)
            guard !Task.isCancelled else { return }
            queue.acknowledge()
        }
    }

    @ViewBuilder
    private var icon: some View {
        if queue.isRunning {
            // Drawn by hand rather than with ProgressView: the circular style on
            // iOS ignores `value` and spins indeterminately, which would say
            // "working" while hiding how far along a long batch actually is.
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.15), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(queue.progress, 0.02))
                    .stroke(Color.accentColor,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 21, height: 21)
            .animation(.snappy(duration: 0.3), value: queue.progress)
        } else if let outcome = queue.outcome {
            Image(systemName: outcome.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(outcome.failed.isEmpty ? Color.statusDone : .orange)
        }
    }

    private var title: String {
        if queue.isRunning { return "Sending mail" }
        guard let outcome = queue.outcome else { return "" }
        if outcome.failed.isEmpty {
            return outcome.sent == 1 ? "Mail sent" : "\(outcome.sent) mails sent"
        }
        return "\(outcome.sent) sent · \(outcome.failed.count) failed"
    }

    private var subtitle: String {
        if queue.isRunning {
            return "\(queue.completed) of \(queue.total) · keep the app open"
        }
        guard let outcome = queue.outcome, !outcome.failed.isEmpty else { return "Tap to dismiss" }
        return "Couldn't reach \(outcome.failed.prefix(2).joined(separator: ", "))"
            + (outcome.failed.count > 2 ? " and \(outcome.failed.count - 2) more" : "")
    }

    @ViewBuilder
    private var trailingControl: some View {
        if queue.isRunning {
            Button {
                queue.cancel()
            } label: {
                Text("Stop")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if queue.outcome != nil {
            Button {
                queue.acknowledge()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}
