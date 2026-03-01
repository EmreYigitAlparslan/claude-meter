import Foundation
import Combine

struct UsageData {
    var sessionPercent: Int?
    var sessionResets: String?
    var weeklyPercent: Int?
    var weeklyResets: String?
    var rawOutput: String = ""
    var lastUpdated: Date?
    var error: String?
}

class UsageMonitor: ObservableObject {
    @Published var usage = UsageData()
    @Published var isLoading = false

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 300 // 5 minutes

    init() {
        refresh()
        startTimer()
    }

    func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
            self.refresh()
        }
    }

    func refresh() {
        isLoading = true
        DispatchQueue.global(qos: .background).async {
            let result = self.fetchUsage()
            DispatchQueue.main.async {
                self.usage = result
                self.isLoading = false
            }
        }
    }

    private func fetchUsage() -> UsageData {
        var data = UsageData()

        // Find claude binary
        let claudePath = findClaude()
        guard let claude = claudePath else {
            data.error = "claude not found in PATH"
            return data
        }

        // Use bundled Python PTY script to interact with claude
        guard let scriptPath = Bundle.main.path(forResource: "fetch_usage", ofType: "py") else {
            data.error = "fetch_usage.py not found in bundle"
            return data
        }

        let python = findPython()
        guard let py = python else {
            data.error = "Python3 not found"
            return data
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: py)
        process.arguments = [scriptPath, claude]

        // Extend PATH so node/claude are findable from app bundle
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin"
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = extraPaths + (currentPath.isEmpty ? "" : ":" + currentPath)
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            // Timeout: max 25 seconds
            let deadline = Date().addingTimeInterval(25)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
            }
            if process.isRunning { process.terminate() }

            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: outputData, encoding: .utf8) ?? ""
            data.rawOutput = raw
            data = parseJSON(output: outputData, data: data)
        } catch {
            data.error = error.localizedDescription
        }

        return data
    }

    private func parseJSON(output: Data, data: UsageData) -> UsageData {
        var result = data
        result.lastUpdated = Date()

        // Python script outputs a single JSON line at the end
        // Find it by looking for the last line starting with {
        let text = String(data: output, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: .newlines)
        guard let jsonLine = lines.last(where: { $0.hasPrefix("{") }),
              let jsonData = jsonLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            if text.contains("Not logged in") || text.contains("login") {
                result.error = "Not logged in — run: claude login"
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.error = "No output from claude"
            } else {
                result.error = "Couldn't parse output (see raw)"
            }
            return result
        }

        result.sessionPercent = json["session"] as? Int
        result.weeklyPercent = json["weekly"] as? Int
        result.sessionResets = json["sessionResets"] as? String
        result.weeklyResets = json["weeklyResets"] as? String

        if result.sessionPercent == nil && result.weeklyPercent == nil {
            result.error = "No usage data in response"
        }

        return result
    }

    private func findPython() -> String? {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func findClaude() -> String? {
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.nvm/versions/node/current/bin/claude",
            "/usr/bin/claude"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try `which claude` as fallback
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "which claude 2>/dev/null || command -v claude 2>/dev/null"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }

}
