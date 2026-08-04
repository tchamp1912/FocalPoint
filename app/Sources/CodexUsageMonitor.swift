// Optional Codex app-server account quota monitor.
//
// It uses the documented JSON-RPC account/rateLimits/read API over a local
// `codex app-server` stdio transport. The process reuses Codex's ChatGPT auth;
// API-key accounts do not expose rate-limit data. Organization owners can
// optionally provide OPENAI_ADMIN_KEY to publish the current UTC day's API
// spend as a separate `openai-api` usage record. The key stays in this process
// environment and is never sent to focalpointd or persisted by the app.

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
            let rateLimitValues = Self.readRateLimits()
            let apiBilledValues = Self.readAPIBilledUsage()
            DispatchQueue.main.async {
                guard let model = self?.model else { return }
                if let values = rateLimitValues {
                    model.client.send([
                        "cmd": "set-usage",
                        "provider": "codex",
                        "usage": values,
                    ])
                }
                if let values = apiBilledValues {
                    model.client.send([
                        "cmd": "set-usage",
                        "provider": "openai-api",
                        "usage": values,
                    ])
                }
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

    /// The Organization Costs endpoint requires an Admin API key; deliberately
    /// do not fall back to OPENAI_API_KEY because ordinary/project keys are not
    /// authorized for this endpoint. Reporting uses a distinct provider so a
    /// previous ChatGPT quota snapshot cannot be mistaken for API billing.
    private static func readAPIBilledUsage() -> [String: Double]? {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_ADMIN_KEY"],
              !key.isEmpty else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date()
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start),
              var components = URLComponents(string: "https://api.openai.com/v1/organization/costs") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(end.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        guard let data = syncData(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = json["data"] as? [[String: Any]] else { return nil }

        let spend = buckets.flatMap { $0["results"] as? [[String: Any]] ?? [] }
            .compactMap { (($0["amount"] as? [String: Any])?["value"] as? NSNumber)?.doubleValue }
            .reduce(0, +)
        guard spend.isFinite, spend >= 0 else { return nil }
        return [
            "api_spend_usd": spend,
            "api_spend_period_started_at": start.timeIntervalSince1970,
            "api_spend_period_ends_at": end.timeIntervalSince1970,
        ]
    }

    private static func syncData(for request: URLRequest) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return }
            result = data
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 12)
        return result
    }
}
