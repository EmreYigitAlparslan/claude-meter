import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        HStack(spacing: 4) {
            Image("MenuBarIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)

            if monitor.isLoading {
                Text("…")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            } else if let error = monitor.usage.error {
                Text("!")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.red)
                    .help(error)
            } else {
                let session = monitor.usage.sessionPercent.map { "\($0)%" } ?? "?"
                let weekly = monitor.usage.weeklyPercent.map { "\($0)%" } ?? "?"
                Text("\(session) · \(weekly)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
    }
}
