// Optional Anthropic API-account usage monitor.
//
// The Admin API reports exact organization token usage. It does not return a
// billing total, so this publishes tokens rather than guessing a dollar cost.

import Foundation

final class ClaudeUsageMonitor {
    private var timer: Timer?
    private var running = false
    private weak var model: AppModel?

    init(model: AppModel) { self.model = model }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard !running else { return }
        running = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { DispatchQueue.main.async { self?.running = false } }
            guard let values = Self.readUsage() else { return }
            DispatchQueue.main.async {
                self?.model?.client.send(["cmd": "set-usage", "provider": "claude-api", "usage": values])
            }
        }
    }

    private static func readUsage() -> [String: Double]? {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_ADMIN_KEY"], !key.isEmpty,
              var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/usage_report/messages") else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: Date())
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: ISO8601DateFormatter().string(from: start)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 10
        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        URLSession.shared.dataTask(with: request) { response, http, _ in
            defer { semaphore.signal() }
            guard let status = http as? HTTPURLResponse, (200...299).contains(status.statusCode) else { return }
            data = response
        }.resume()
        _ = semaphore.wait(timeout: .now() + 12)
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = json["data"] as? [[String: Any]] else { return nil }
        var input = 0.0, output = 0.0
        for result in buckets.flatMap({ $0["results"] as? [[String: Any]] ?? [] }) {
            input += number(result["uncached_input_tokens"])
            input += number(result["cache_read_input_tokens"])
            if let cache = result["cache_creation"] as? [String: Any] {
                input += number(cache["ephemeral_1h_input_tokens"])
                input += number(cache["ephemeral_5m_input_tokens"])
            }
            output += number(result["output_tokens"])
        }
        return [
            "api_input_tokens": input,
            "api_output_tokens": output,
            "api_spend_period_started_at": start.timeIntervalSince1970,
            "api_spend_period_ends_at": start.addingTimeInterval(86_400).timeIntervalSince1970,
        ]
    }

    private static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
}
