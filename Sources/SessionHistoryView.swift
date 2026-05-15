import SwiftUI

struct SessionHistoryView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager

    var body: some View {
        List {
            if sessionManager.sessionHistory.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "target",
                    description: Text("Completed focus sessions will show up here.")
                )
            } else {
                ForEach(sessionManager.sessionHistory) { session in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(session.allowedAppName)
                                .font(.headline)
                            Spacer()
                            Text(session.elapsed.formattedDuration)
                                .foregroundStyle(.secondary)
                        }

                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Label("\(session.violations.count)", systemImage: "exclamationmark.triangle")
                            Label("\(session.escapes.count)", systemImage: "timer")
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
