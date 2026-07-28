// Optional Cursor account quota monitor.
//
// Reads the signed-in Cursor app's local access token (SQLite state DB) and
// queries Cursor's undocumented dashboard API — the same endpoints community
// usage extensions use. No prompts, hooks, or session data leave the machine
// beyond the HTTPS quota request.

import Foundation

final class CursorUsageMonitor {
    private static let apiBase = URL(string: "https://api2.cursor.sh")!
    private static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
    private static let dbPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")

    private var timer: Timer?
    private var running = false
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
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
            guard let values = Self.readUsage() else { return }
            DispatchQueue.main.async {
                self?.model?.client.send([
                    "cmd": "set-usage",
                    "provider": "cursor",
                    "usage": values,
                ])
            }
        }
    }

    private static func readUsage() -> [String: Double]? {
        guard var token = readAuthValue("cursorAuth/accessToken"), !token.isEmpty else { return nil }
        if isTokenExpired(token), let refreshed = refreshAccessToken() {
            token = refreshed
        }
        if let period = fetchCurrentPeriodUsage(token: token) {
            return period
        }
        return fetchAuthUsage(token: token)
    }

    private static func fetchCurrentPeriodUsage(token: String) -> [String: Double]? {
        guard let url = URL(string: "/aiserver.v1.DashboardService/GetCurrentPeriodUsage", relativeTo: apiBase),
              let data = postJSON(url: url, token: token, body: [:]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = json["planUsage"] as? [String: Any] else { return nil }

        var result: [String: Double] = [:]
        if let api = number(plan["apiPercentUsed"]) { result["primary_used"] = api }
        if let auto = number(plan["autoPercentUsed"]) { result["secondary_used"] = auto }
        if let reset = epochSeconds(json["billingCycleEnd"]) {
            result["primary_resets_at"] = reset
            result["secondary_resets_at"] = reset
        }
        return result.isEmpty ? nil : result
    }

    /// Enterprise-style fallback when `planUsage` is absent.
    private static func fetchAuthUsage(token: String) -> [String: Double]? {
        guard let url = URL(string: "/auth/usage", relativeTo: apiBase),
              let data = get(url: url, token: token),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var bestUsed: Double?
        var bestMax: Double?
        for (key, value) in json where key != "startOfMonth" {
            guard let bucket = value as? [String: Any],
                  let max = number(bucket["maxRequestUsage"]), max > 0,
                  let used = number(bucket["numRequests"]) else { continue }
            if bestMax == nil || max > bestMax! {
                bestMax = max
                bestUsed = used
            }
        }
        guard let used = bestUsed, let limit = bestMax else { return nil }
        var result = ["primary_used": Swift.min(Swift.max(used / limit * 100, 0), 100)]
        if let start = json["startOfMonth"] as? String,
           let date = ISO8601DateFormatter().date(from: start) {
            let end = Calendar.current.date(byAdding: .month, value: 1, to: date) ?? date
            result["primary_resets_at"] = end.timeIntervalSince1970
        }
        return result
    }

    private static func readAuthValue(_ key: String) -> String? {
        guard FileManager.default.fileExists(atPath: dbPath.path) else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath.path, "SELECT value FROM ItemTable WHERE key = '\(key)';"]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let raw = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    private static func refreshAccessToken() -> String? {
        guard let refresh = readAuthValue("cursorAuth/refreshToken"), !refresh.isEmpty,
              let url = URL(string: "/oauth/token", relativeTo: apiBase) else { return nil }
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refresh,
        ]
        guard let data = postJSON(url: url, token: nil, body: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["shouldLogout"] as? Bool) != true,
              let token = json["access_token"] as? String, !token.isEmpty else { return nil }
        return token
    }

    private static func postJSON(url: URL, token: String?, body: [String: Any]) -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return syncData(for: request)
    }

    private static func get(url: URL, token: String) -> Data? {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return syncData(for: request)
    }

    private static func syncData(for request: URLRequest) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
            result = data
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        return result
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func epochSeconds(_ value: Any?) -> Double? {
        if let ms = number(value) { return ms / 1000 }
        if let raw = value as? String, let ms = Double(raw) { return ms / 1000 }
        return nil
    }

    private static func isTokenExpired(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payload = base64URLDecode(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let exp = number(json["exp"]) else { return false }
        return Date().timeIntervalSince1970 >= exp - 60
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        return Data(base64Encoded: base64)
    }
}
