import SwiftUI

/// Inline `.formatted(date:time:)` calls inside ViewBuilders trip type inference, so the
/// formatting lives here.
private func clockTime(_ date: Date) -> String {
    clockTime(date)
}

/// The day, in the order the brief asks for: what got past the rules first, then the
/// numbers, then the sessions (3.11).
struct DailyReviewView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager
    @State private var date = Date()
    @State private var review: DailyReview?
    @State private var exportPath: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let review, !review.isEmpty {
                List {
                    if !review.overrides.isEmpty { overridesSection(review) }
                    if !review.safeModeEntries.isEmpty { safeModeSection(review) }
                    if !review.gaps.isEmpty || !review.buildChanges.isEmpty || !review.permissionEvents.isEmpty {
                        integritySection(review)
                    }
                    totalsSection(review)
                    if !review.fullSessions.isEmpty { fullSessionsSection(review) }
                    if !review.openSessions.isEmpty { openSessionsSection(review) }
                    if !review.additions.isEmpty { additionsSection(review) }
                    if !sessionManager.pendingChanges.isEmpty { pendingSection }
                }
            } else {
                ContentUnavailableView(
                    "Nothing recorded",
                    systemImage: "calendar",
                    description: Text("No sessions, and no time at the Mac, on this day.")
                )
                .frame(maxHeight: .infinity)
            }
        }
        .onAppear(perform: load)
        .onChange(of: date) { _, _ in load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            DatePicker("", selection: $date, displayedComponents: .date)
                .labelsHidden()

            Button("Today") { date = Date() }

            Spacer()

            if let exportPath {
                Text(exportPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Button("Export JSON") {
                exportPath = sessionManager.exportDay(date)?.path
            }
        }
        .padding(12)
    }

    private func load() {
        review = sessionManager.dailyReview(for: date)
        exportPath = nil
    }

    // MARK: - Sections

    private func overridesSection(_ review: DailyReview) -> some View {
        Section("Overrides") {
            ForEach(review.overrides) { override in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Label(override.reason, systemImage: "lock.open.trianglebadge.exclamationmark.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Text(override.duration.map { $0.formattedDuration } ?? "running")
                            .monospacedDigit()
                    }
                    Text(clockTime(override.startedAt)
                        + (override.early ? " · ended early" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func safeModeSection(_ review: DailyReview) -> some View {
        Section("Safe mode") {
            ForEach(review.safeModeEntries) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Label(
                        entry.reason == .crashLoop ? "Crash loop" : "Restart escape",
                        systemImage: "exclamationmark.shield.fill"
                    )
                    Text("\(clockTime(entry.at)) · \(entry.detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func integritySection(_ review: DailyReview) -> some View {
        Section("Gaps and changes") {
            ForEach(review.gaps) { gap in
                VStack(alignment: .leading, spacing: 3) {
                    Label("Not running from \(clockTime(gap.from)) to \(clockTime(gap.to))", systemImage: "bolt.slash.fill")
                    Text(gap.explained
                        ? "Explained by sleep, shutdown or a clean quit"
                        : "Unexplained · \(gap.duration.formattedDuration)")
                        .font(.caption)
                        .foregroundStyle(gap.explained ? Color.secondary : Color.orange)
                }
                .padding(.vertical, 2)
            }

            ForEach(review.buildChanges) { change in
                Label(
                    "Build changed: \(change.previousVersion ?? "unknown") → \(change.version)"
                        + (change.signatureChanged ? " (signature too)" : ""),
                    systemImage: "hammer.fill"
                )
                .font(.callout)
            }

            ForEach(review.permissionEvents) { event in
                Label(
                    "\(event.permission.capitalized) \(event.lost ? "lost" : "restored") at \(clockTime(event.at))",
                    systemImage: event.lost ? "exclamationmark.octagon.fill" : "checkmark.seal.fill"
                )
                .font(.callout)
                .foregroundStyle(event.lost ? Color.red : Color.secondary)
            }
        }
    }

    private func totalsSection(_ review: DailyReview) -> some View {
        Section("Totals") {
            HStack(spacing: 26) {
                Stat(label: "Active at the Mac", value: review.totals.activeSeconds.formattedDuration)
                Stat(label: "In full sessions", value: review.totals.fullSessionSeconds.formattedDuration)
                Stat(label: "In open sessions", value: review.totals.openSessionSeconds.formattedDuration)
                Stat(label: "Covered", value: "\(Int(review.totals.coverage * 100))%")
            }
            .padding(.vertical, 4)

            ProgressView(value: review.totals.coverage)

            Text("\(review.gateShownCount) trips through the gate"
                + (review.sleepRequests > 0 ? " · called it a day \(review.sleepRequests)×" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func fullSessionsSection(_ review: DailyReview) -> some View {
        Section("Full sessions") {
            ForEach(review.fullSessions) { SessionRow(entry: $0) }
        }
    }

    private func openSessionsSection(_ review: DailyReview) -> some View {
        Section("Open sessions" + (review.chains.isEmpty ? "" : " · \(review.chains.count) chained")) {
            ForEach(review.openSessions) { SessionRow(entry: $0) }
        }
    }

    private func additionsSection(_ review: DailyReview) -> some View {
        Section("Added mid-session") {
            ForEach(review.additions) { addition in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(addition.target) — “\(addition.reason)”")
                    Text("\(clockTime(addition.at)) · during “\(addition.sessionGoal)”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var pendingSection: some View {
        Section("Waiting to take effect") {
            ForEach(sessionManager.pendingChanges) { pending in
                VStack(alignment: .leading, spacing: 3) {
                    Text(pending.change.summary)
                    Text(sessionManager.countdown(to: pending.effectiveAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct SessionRow: View {
    let entry: DailyReview.SessionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.goal)
                    .font(.body.weight(.medium))
                if entry.chainedFromPrevious {
                    Text("chained")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.25))
                        .clipShape(Capsule())
                }
                Spacer()
                Text(clockTime(entry.startedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                if let planned = entry.plannedSeconds {
                    Text("planned \(planned.formattedDuration) · actual \(entry.actualSeconds.formattedDuration)")
                } else {
                    Text(entry.actualSeconds.formattedDuration)
                }
                if let outcome = entry.outcome {
                    Text(outcome.rawValue)
                        .foregroundStyle(outcome == .finished ? Color.green : Color.secondary)
                }
                if entry.violations > 0 { Label("\(entry.violations)", systemImage: "exclamationmark.triangle") }
                if entry.additions > 0 { Label("\(entry.additions)", systemImage: "plus.app") }
                if entry.extended { Text("extended") }
                if entry.converted { Text("converted") }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            if !entry.appsUsed.isEmpty {
                Text(entry.appsUsed.sorted { $0.seconds > $1.seconds }.prefix(5).map(\.name).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
