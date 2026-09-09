import Foundation

@main
enum ManagedProjectFoldersTests {
    static func main() throws {
        let suite = "ManagedProjectFoldersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        precondition(ManagedProjectFolders.normalize("~/Projects/../Work") == home + "/Work")
        precondition(ManagedProjectFolders.normalize(" /tmp/project/../other/ ") == "/tmp/other")
        precondition(ManagedProjectFolders.normalize("relative/project") == nil)
        precondition(ManagedProjectFolders.normalize("") == nil)
        precondition(ManagedProjectFolders.normalize("/tmp/\0project") == nil)
        precondition(ManagedProjectFolders.normalize("/tmp/\nproject") == nil)
        precondition(ManagedProjectFolders.normalize("/" + String(repeating: "a", count: 4_096)) == nil)

        let folders = ManagedProjectFolders(defaults: defaults, directoryExists: { $0.hasPrefix("/projects/") })
        precondition(folders.pinned.isEmpty && folders.recent.isEmpty)
        precondition(!folders.remember("relative"))
        precondition(!folders.remember("/missing"))
        precondition(!folders.togglePin("/missing"))
        precondition(folders.remember("/projects/one"))
        precondition(folders.remember("/projects/two"))
        precondition(folders.remember("/projects/one/../one/"))
        precondition(folders.recent == ["/projects/one", "/projects/two"], "remember should deduplicate and move to front")
        for index in 0..<15 { precondition(folders.remember("/projects/recent-\(index)")) }
        precondition(folders.recent.count == 12)
        precondition(folders.recent.first == "/projects/recent-14")
        precondition(folders.recent.last == "/projects/recent-3")
        for index in 0..<20 { precondition(folders.togglePin("/projects/pin-\(index)")) }
        precondition(!folders.togglePin("/projects/overflow"), "full pins must not silently evict a project")
        precondition(folders.pinned.count == 20)
        precondition(folders.pinned.first == "/projects/pin-0")
        precondition(folders.togglePin("/projects/pin-0/"))
        precondition(!folders.pinned.contains("/projects/pin-0"))
        precondition(folders.togglePin("/projects/overflow"))

        // A reload preserves unavailable paths without consulting existence.
        let offline = ManagedProjectFolders(defaults: defaults, directoryExists: { _ in false })
        precondition(offline.pinned == folders.pinned && offline.recent == folders.recent)
        precondition(offline.togglePin("/projects/overflow"), "offline pins must be removable")
        precondition(!offline.togglePin("/projects/overflow"), "offline paths cannot be newly pinned")
        offline.clearRecent()
        precondition(offline.recent.isEmpty)
        precondition(defaults.object(forKey: ManagedProjectFolders.recentKey) == nil)
        precondition(!offline.pinned.isEmpty, "clearing recent history must preserve pins")
        precondition(ManagedProjectFolders(defaults: defaults).pinned == offline.pinned)

        // Persisted duplicates and malformed entries do not leak into menus.
        defaults.set(["relative", "/Volumes/offline/project/", "/Volumes/offline/./project", "~/Work"],
                     forKey: ManagedProjectFolders.pinnedKey)
        defaults.set(Array(repeating: "/Volumes/offline/project", count: 20) + (0..<30).map { "/projects/\($0)" },
                     forKey: ManagedProjectFolders.recentKey)
        let cleaned = ManagedProjectFolders(defaults: defaults, directoryExists: { _ in false })
        precondition(cleaned.pinned == ["/Volumes/offline/project", home + "/Work"])
        precondition(cleaned.recent.count == 12)
        precondition(Set(cleaned.recent).count == cleaned.recent.count)
        precondition(cleaned.recent.first == "/Volumes/offline/project")
        print("ManagedProjectFoldersTests: PASS")
    }
}
