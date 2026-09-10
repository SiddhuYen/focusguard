import SwiftUI

/// Fills a display while the gate is up. The main display gets the setup UI; the others
/// get a dark cover so nothing behind them is usable.
struct ShieldRootView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager
    let isPrimary: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.06), Color(red: 0.09, green: 0.10, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if isPrimary {
                GateView()
                    .frame(maxWidth: 720)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "target")
                        .font(.system(size: 34, weight: .light))
                    Text("Focus Guard")
                        .font(.title3.weight(.medium))
                    Text("State your goal on the main display.")
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white.opacity(0.55))
            }

            #if DEBUG
            VStack {
                HStack {
                    Spacer()
                    Button("DEBUG: dismiss") { ShieldWindowController.shared.hide() }
                        .padding(12)
                }
                Spacer()
            }
            #endif
        }
        .preferredColorScheme(.dark)
    }
}
