import SwiftUI

/// Fills a display while the gate is up. The main display gets the setup UI; the others
/// get a dark cover so nothing behind them is usable.
struct ShieldRootView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager
    let isPrimary: Bool
    /// Debug only, for offscreen rendering.
    var demoLines: [TerminalLine]?

    var body: some View {
        ZStack {
            TerminalPalette.background.ignoresSafeArea()

            if isPrimary {
                TerminalGateView(demoLines: demoLines)
            } else {
                VStack(spacing: 8) {
                    Text("focus guard")
                        .foregroundStyle(TerminalPalette.text)
                    Text("state your goal on the main display")
                        .foregroundStyle(TerminalPalette.dim)
                }
                .font(.system(size: 14, design: .monospaced))
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
}
