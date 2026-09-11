import SwiftUI

/// Fills a display while the shield is up. The main display gets the gate or the review;
/// the others get a dark cover so nothing behind them is usable.
struct ShieldRootView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager
    let isPrimary: Bool
    var content: ShieldWindowController.Content?
    /// Debug only, for offscreen rendering.
    var demoLines: [TerminalLine]?

    var body: some View {
        ZStack {
            TerminalPalette.background.ignoresSafeArea()

            switch content {
            case .some(.review(let session, let reason)):
                if isPrimary {
                    review(session: session, reason: reason)
                } else {
                    cover(title: reason == .timeUp ? "time's up" : "ending the session",
                          subtitle: "answer on the main display")
                }
            default:
                if isPrimary {
                    TerminalGateView(demoLines: demoLines)
                } else {
                    cover(title: "focus guard", subtitle: "state your goal on the main display")
                }
            }

            #if DEBUG
            VStack {
                HStack {
                    Spacer()
                    Button {
                        ShieldWindowController.shared.hide()
                    } label: {
                        Text("[debug: dismiss]")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(TerminalPalette.dim)
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }
                Spacer()
            }
            #endif
        }
        .preferredColorScheme(.dark)
    }

    /// The review, over the same black as the gate. It stays until it is answered; the
    /// emergency override is the only other way past, as everywhere else the Mac is locked.
    private func review(session: Session, reason: ReviewReason) -> some View {
        VStack(spacing: 16) {
            Text(reason == .timeUp ? "time's up" : "ending the session")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(TerminalPalette.text)

            ReviewView(session: session, reason: reason)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(TerminalPalette.dim))

            Button {
                sessionManager.presentOverrideFromIntervention()
            } label: {
                Text("[emergency override]")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TerminalPalette.dim)
            }
            .buttonStyle(.plain)
        }
    }

    private func cover(title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .foregroundStyle(TerminalPalette.text)
            Text(subtitle)
                .foregroundStyle(TerminalPalette.dim)
        }
        .font(.system(size: 14, design: .monospaced))
    }
}
