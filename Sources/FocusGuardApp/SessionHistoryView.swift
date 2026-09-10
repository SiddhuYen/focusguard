import SwiftUI

struct SessionHistoryView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager

    var body: some View {
        List {
            if sessionManager.sessionHistory.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "target",
                    description: Text("Completed sessions will show up here.")
                )
            } else {
                ForEach(sessionManager.sessionHistory) { session in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(session.anchorName)
                                .font(.headline)
                            if session.kind == .open {
                                Text("open")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                            Spacer()
                            Text(session.duration.formattedDuration)
                                .foregroundStyle(.secondary)
                        }

                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(session.goal)
                            .font(.caption)

                        HStack(spacing: 12) {
                            Label("\(session.violationCount)", systemImage: "exclamationmark.triangle")
                            if session.additionCount > 0 {
                                Label("\(session.additionCount)", systemImage: "plus.app")
                            }
                            if session.escapeCount > 0 {
                                Label("\(session.escapeCount)", systemImage: "timer")
                            }
                            if let outcome = session.outcome {
                                Text(outcome.rawValue)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }
}
