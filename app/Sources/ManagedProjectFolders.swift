// FocalPoint quick launcher — pinned and recently used project folders.
// Persists folder paths only; prompts and launch identities are never stored.
// MIT License.

import Foundation

final class ManagedProjectFolders {
    static let pinnedKey = "managedProjectFolders.pinned.v1"
    static let recentKey = "managedProjectFolders.recent.v1"
    static let pinnedLimit = 20
    static let recentLimit = 12

    private(set) var pinned: [String]
    private(set) var recent: [String]
    private let defaults: UserDefaults
    private let directoryExists: (String) -> Bool

    init(defaults: UserDefaults = .standard,
         directoryExists: @escaping (String) -> Bool = { path in
             var isDirectory: ObjCBool = false
             return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                 && isDirectory.boolValue
         }) {
        self.defaults = defaults
        self.directoryExists = directoryExists
        // External volumes and temporarily unavailable projects remain in the
        // list. Existence is checked only when explicitly adding a folder.
        pinned = Self.loaded(defaults.stringArray(forKey: Self.pinnedKey) ?? [], limit: Self.pinnedLimit)
        recent = Self.loaded(defaults.stringArray(forKey: Self.recentKey) ?? [], limit: Self.recentLimit)
    }

    static func normalize(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4_096,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let normalized = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
        guard normalized.utf8.count <= 4_096 else { return nil }
        return normalized
    }

    /// Move an existing folder to the front of recent history.
    @discardableResult
    func remember(_ path: String) -> Bool {
        guard let path = Self.normalize(path), directoryExists(path) else { return false }
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        recent = Array(recent.prefix(Self.recentLimit))
        defaults.set(recent, forKey: Self.recentKey)
        return true
    }

    /// Unpinning also works when a drive is disconnected. Adding a new pin
    /// checks existence and never evicts another pinned project.
    @discardableResult
    func togglePin(_ path: String) -> Bool {
        guard let path = Self.normalize(path) else { return false }
        if pinned.contains(path) {
            pinned.removeAll { $0 == path }
        } else {
            guard pinned.count < Self.pinnedLimit, directoryExists(path) else { return false }
            pinned.append(path)
        }
        if pinned.isEmpty { defaults.removeObject(forKey: Self.pinnedKey) }
        else { defaults.set(pinned, forKey: Self.pinnedKey) }
        return true
    }

    func clearRecent() {
        recent = []
        defaults.removeObject(forKey: Self.recentKey)
    }

    private static func loaded(_ paths: [String], limit: Int) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for path in paths {
            guard let normalized = normalize(path), seen.insert(normalized).inserted else { continue }
            result.append(normalized)
            if result.count == limit { break }
        }
        return result
    }
}
