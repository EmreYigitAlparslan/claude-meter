import SwiftUI

struct MenuView: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Text("Claude Meter")
                    .font(.headline)
                Spacer()
            }

            Divider()

            if monitor.isLoading {
                HStack {
                    ProgressView().scaleEffect(0.7)
                    Text("Fetching usage…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else if let error = monitor.usage.error {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundColor(.orange)

                    if !monitor.usage.rawOutput.isEmpty {
                        DisclosureGroup("Raw output") {
                            ScrollView {
                                Text(monitor.usage.rawOutput)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 120)
                        }
                        .font(.caption)
                    }
                }
            } else {
                // Session usage
                UsageRow(
                    label: "Session",
                    percent: monitor.usage.sessionPercent,
                    resets: monitor.usage.sessionResets,
                    icon: "clock"
                )

                // Weekly usage
                UsageRow(
                    label: "Week (all models)",
                    percent: monitor.usage.weeklyPercent,
                    resets: monitor.usage.weeklyResets,
                    icon: "calendar"
                )
            }

            Divider()

            // Footer
            HStack {
                if let date = monitor.usage.lastUpdated {
                    Text("Updated \(date, style: .relative) ago")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Refresh") { monitor.refresh() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .disabled(monitor.isLoading)

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

struct UsageRow: View {
    let label: String
    let percent: Int?
    var resets: String? = nil
    let icon: String

    var color: Color {
        guard let p = percent else { return .gray }
        if p >= 80 { return .red }
        if p >= 60 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(label, systemImage: icon)
                    .font(.subheadline)
                Spacer()
                Text(percent.map { "\($0)%" } ?? "—")
                    .font(.subheadline.bold())
                    .foregroundColor(color)
            }
            if let p = percent {
                ProgressView(value: Double(p), total: 100)
                    .tint(color)
            }
            if let r = resets {
                Text(r)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}
