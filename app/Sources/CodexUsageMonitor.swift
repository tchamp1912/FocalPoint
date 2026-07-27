// Optional Codex app-server account quota monitor.
//
// It uses the documented JSON-RPC account/rateLimits/read API over a local
// `codex app-server` stdio transport. The process reuses Codex's ChatGPT auth;
// API-key accounts simply return no rate-limit data.

import Foundation

final class CodexUsageMonitor {
    private var timer: Timer?
    private var running = false
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !running else { return }
        running = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer {
                DispatchQueue.main.async { self?.running = false }
            }
            guard let values = Self.readRateLimits() else { return }
            DispatchQueue.main.async {
                self?.model?.client.send([
                    "cmd": "set-usage",
                    "provider": "codex",
                    "usage": values,
                ])
            }
        }
    }

    private static func readRateLimits() -> [String: Double]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "app-server"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        defer {
            if process.isRunning { process.terminate() }
        }

        let requests: [[String: Any]] = [
            ["method": "initialize", "id": 0,
             "params": ["clientInfo": ["name": "focalpoint", "title": "FocalPoint", "version": "0.1"]]],
            ["method": "initialized", "params": [:]],
            ["method": "account/rateLimits/read", "id": 1],
        ]
        for request in requests {
            guard let data = try? JSONSerialization.data(withJSONObject: request),
                  let line = String(data: data, encoding: .utf8) else { return nil }
            input.fileHandleForWriting.write(Data((line + "\n").utf8))
        }

        let reader = output.fileHandleForReading
        let deadline = Date().addingTimeInterval(5)
        var buffered = Data()
        while Date() < deadline {
            let data = reader.availableData
            guard !data.isEmpty else { break }
            buffered.append(data)
            while let newline = buffered.firstIndex(of: 0x0A) {
                let line = buffered.prefix(upTo: newline)
                buffered.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (object["id"] as? NSNumber)?.intValue == 1,
                      let result = object["result"] as? [String: Any],
                      let limits = result["rateLimits"] as? [String: Any] else { continue }
                return normalize(limits)
            }
        }
        return nil
    }

    private static func normalize(_ limits: [String: Any]) -> [String: Double]? {
        var result: [String: Double] = [:]
        addWindow(limits["primary"] as? [String: Any], prefix: "primary", into: &result)
        addWindow(limits["secondary"] as? [String: Any], prefix: "secondary", into: &result)
        return result.isEmpty ? nil : result
    }

    private static func addWindow(_ window: [String: Any]?, prefix: String,
                                  into result: inout [String: Double]) {
        guard let window else { return }
        if let used = (window["usedPercent"] as? NSNumber)?.doubleValue {
            result["\(prefix)_used"] = used
        }
        if let reset = (window["resetsAt"] as? NSNumber)?.doubleValue {
            result["\(prefix)_resets_at"] = reset
        }
        if let duration = (window["windowDurationMins"] as? NSNumber)?.doubleValue {
            result["\(prefix)_window_minutes"] = duration
        }
    }
}
