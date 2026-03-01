import SwiftUI

@main
struct ClaudeUsageApp: App {
    @StateObject private var monitor = UsageMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuView(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}
