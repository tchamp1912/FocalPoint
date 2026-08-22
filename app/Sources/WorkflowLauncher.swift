// FocalPoint menu-bar app — workflow launcher (WORKFLOWS-PROPOSAL.md §8.2).
//
// Lists formation packages installed under ~/.config/focalpoint/workflows/
// and starts one. The architectural boundary is deliberate and load-bearing:
// the app CANNOT run a formation itself. It launches exactly ONE agent — the
// formation's orchestrator — via the daemon's `launch-session` primitive, and
// that orchestrator validates, expands, and sequences the crew (spec §3, §5.2).
// The app never parses a manifest into launch calls, never picks providers per
// role, and never creates channels.
//
// Manifests are read with a small TOML subset parser (below) — swiftc-only
// build means no package dependencies, and the schema (docs/workflows-schema.md)
// uses a narrow slice of TOML: tables, arrays of tables, strings, integers,
// booleans, and string arrays.
// MIT License.

import SwiftUI
import AppKit
import Combine

// MARK: - Minimal TOML subset parser (formation manifests only)
//
// Module-internal (not private) so the workflow editor (WorkflowEditor.swift)
// loads packages through the exact same parser the launcher validates with —
// one TOML dialect for the whole app.

enum TomlValue {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([TomlValue])
    case table([String: TomlValue])
    case tableArray([[String: TomlValue]])
}

struct TomlError: Error {
    let line: Int
    let message: String
}

/// Value-level parse failure. `parse` knows the line number; the value
/// parsers don't, so they fail with this and `parse` rethrows as TomlError.
struct TomlValueError: Error {
    let message: String
}

/// Schema-v1 validation failure — the reason shown beside the package.
private struct ManifestInvalid: Error {
    let message: String
}

enum TomlParser {

    static func parse(_ text: String) -> Result<[String: TomlValue], TomlError> {
        var root: [String: TomlValue] = [:]
        var currentPath: [String] = []
        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let lineNo = i + 1
            let stripped = stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
            i += 1
            if stripped.isEmpty { continue }

            if stripped.hasPrefix("[[") {
                guard stripped.hasSuffix("]]"),
                      let path = parsePath(stripped.dropFirst(2).dropLast(2)) else {
                    return .failure(TomlError(line: lineNo, message: "malformed [[table-array]] header"))
                }
                currentPath = path
                if let error = appendTableArray(at: path, into: &root) {
                    return .failure(TomlError(line: lineNo, message: error))
                }
            } else if stripped.hasPrefix("[") {
                guard stripped.hasSuffix("]"),
                      let path = parsePath(stripped.dropFirst().dropLast()) else {
                    return .failure(TomlError(line: lineNo, message: "malformed [table] header"))
                }
                currentPath = path
                if let error = ensureTable(at: path, into: &root) {
                    return .failure(TomlError(line: lineNo, message: error))
                }
            } else {
                guard let eq = stripped.firstIndex(of: "=") else {
                    return .failure(TomlError(line: lineNo, message: "expected key = value"))
                }
                let key = stripped[..<eq].trimmingCharacters(in: .whitespaces)
                guard isBareKey(key) else {
                    return .failure(TomlError(line: lineNo, message: "unsupported key '\(key)'"))
                }
                var valueText = String(stripped[stripped.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces)
                // Pretty-printed arrays may span lines; accumulate until the
                // brackets balance (strings respected).
                while valueText.hasPrefix("[") && !arrayIsComplete(valueText) && i < lines.count {
                    valueText += "\n" + stripComment(lines[i])
                    i += 1
                }
                switch parseValue(valueText) {
                case .failure(let error):
                    return .failure(TomlError(line: lineNo, message: error.message))
                case .success(let value):
                    if let error = setValue(value, key: key, at: currentPath, into: &root) {
                        return .failure(TomlError(line: lineNo, message: error))
                    }
                }
            }
        }
        return .success(root)
    }

    // MARK: Table navigation (TOML semantics: descending into an array of
    // tables targets its most recent element)

    /// Ensures the table at `path` exists, creating intermediate tables.
    private static func ensureTable(at path: [String], into root: inout [String: TomlValue]) -> String? {
        mutateTable(at: path[...], in: &root) { _ in nil }
    }

    /// Appends a new empty element to the array of tables at `path`.
    private static func appendTableArray(at path: [String], into root: inout [String: TomlValue]) -> String? {
        guard let last = path.last else { return "empty table path" }
        return mutateTable(at: path.dropLast(), in: &root) { parent in
            switch parent[last] {
            case .none:
                parent[last] = .tableArray([[:]])
                return nil
            case .tableArray(var array):
                array.append([:])
                parent[last] = .tableArray(array)
                return nil
            default:
                return "'\(last)' is already defined and is not an array of tables"
            }
        }
    }

    private static func setValue(_ value: TomlValue, key: String, at path: [String],
                                 into root: inout [String: TomlValue]) -> String? {
        mutateTable(at: path[...], in: &root) { table in
            if table[key] != nil { return "duplicate key '\(key)'" }
            table[key] = value
            return nil
        }
    }

    /// Mutate the table located at `path`, descending into the last element
    /// of any array-of-tables component along the way. Missing intermediate
    /// tables are created. `body` returns nil on success, else an error.
    @discardableResult
    private static func mutateTable(at path: ArraySlice<String>,
                                    in dict: inout [String: TomlValue],
                                    _ body: (inout [String: TomlValue]) -> String?) -> String? {
        guard let head = path.first else { return body(&dict) }
        let key = String(head)
        switch dict[key] {
        case .none:
            var sub: [String: TomlValue] = [:]
            let error = mutateTable(at: path.dropFirst(), in: &sub, body)
            dict[key] = .table(sub)
            return error
        case .table(var sub):
            let error = mutateTable(at: path.dropFirst(), in: &sub, body)
            dict[key] = .table(sub)
            return error
        case .tableArray(var array):
            guard !array.isEmpty else { return "'\(key)' has no element to extend" }
            var last = array.removeLast()
            let error = mutateTable(at: path.dropFirst(), in: &last, body)
            array.append(last)
            dict[key] = .tableArray(array)
            return error
        default:
            return "'\(key)' is a value, not a table"
        }
    }

    // MARK: Lexical helpers

    private static func isBareKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        }
    }

    private static func parsePath(_ raw: Substring) -> [String]? {
        let comps = raw.split(separator: ".", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !comps.isEmpty, comps.allSatisfy(isBareKey) else { return nil }
        return comps
    }

    /// Remove a trailing `#` comment, respecting basic ("...") and literal
    /// ('...') strings.
    private static func stripComment(_ line: String) -> String {
        var inBasic = false, inLiteral = false
        var idx = line.startIndex
        while idx < line.endIndex {
            let c = line[idx]
            if inBasic && c == "\\" {
                idx = line.index(idx, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                continue
            }
            if inBasic {
                if c == "\"" { inBasic = false }
            } else if inLiteral {
                if c == "'" { inLiteral = false }
            } else if c == "\"" {
                inBasic = true
            } else if c == "'" {
                inLiteral = true
            } else if c == "#" {
                return String(line[..<idx])
            }
            idx = line.index(after: idx)
        }
        return line
    }

    /// True when every `[` opened outside a string has been closed.
    private static func arrayIsComplete(_ s: String) -> Bool {
        var depth = 0, inBasic = false, inLiteral = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let c = s[idx]
            if inBasic && c == "\\" {
                idx = s.index(idx, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
                continue
            }
            if inBasic {
                if c == "\"" { inBasic = false }
            } else if inLiteral {
                if c == "'" { inLiteral = false }
            } else if c == "\"" {
                inBasic = true
            } else if c == "'" {
                inLiteral = true
            } else if c == "[" {
                depth += 1
            } else if c == "]" {
                depth -= 1
            }
            idx = s.index(after: idx)
        }
        return depth <= 0
    }

    // MARK: Values

    private static func parseValue(_ raw: String) -> Result<TomlValue, TomlValueError> {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("\"") { return parseBasicString(s) }
        if s.hasPrefix("'") { return parseLiteralString(s) }
        if s == "true" { return .success(.bool(true)) }
        if s == "false" { return .success(.bool(false)) }
        if s.hasPrefix("[") { return parseArray(s) }
        let digits = s.replacingOccurrences(of: "_", with: "")
        if let n = Int(digits) { return .success(.int(n)) }
        return .failure(TomlValueError(message: "unsupported value '\(s.prefix(40))'"))
    }

    private static func parseBasicString(_ s: String) -> Result<TomlValue, TomlValueError> {
        var out = String()
        var idx = s.index(after: s.startIndex)   // skip opening quote
        while idx < s.endIndex {
            let c = s[idx]
            if c == "\\" {
                let next = s.index(after: idx)
                guard next < s.endIndex else {
                    return .failure(TomlValueError(message: "unterminated escape"))
                }
                switch s[next] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "u":
                    let hexStart = s.index(after: next)
                    guard let hexEnd = s.index(hexStart, offsetBy: 4, limitedBy: s.endIndex),
                          hexEnd <= s.endIndex,
                          hexStart < hexEnd,
                          s[hexStart..<hexEnd].count == 4,
                          let codepoint = UInt32(s[hexStart..<hexEnd], radix: 16),
                          let scalar = Unicode.Scalar(codepoint) else {
                        return .failure(TomlValueError(message: "malformed \\u escape"))
                    }
                    out.append(Character(scalar))
                    idx = hexEnd
                    continue
                default:
                    return .failure(TomlValueError(message: "unknown escape '\\\(s[next])'"))
                }
                idx = s.index(after: next)
            } else if c == "\"" {
                let rest = s[s.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                guard rest.isEmpty else {
                    return .failure(TomlValueError(message: "trailing characters after string"))
                }
                return .success(.string(out))
            } else {
                out.append(c)
                idx = s.index(after: idx)
            }
        }
        return .failure(TomlValueError(message: "unterminated string"))
    }

    private static func parseLiteralString(_ s: String) -> Result<TomlValue, TomlValueError> {
        let afterOpen = s.index(after: s.startIndex)
        guard let close = s[afterOpen...].firstIndex(of: "'") else {
            return .failure(TomlValueError(message: "unterminated literal string"))
        }
        let rest = s[s.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty else {
            return .failure(TomlValueError(message: "trailing characters after string"))
        }
        return .success(.string(String(s[afterOpen..<close])))
    }

    private static func parseArray(_ s: String) -> Result<TomlValue, TomlValueError> {
        guard s.hasSuffix("]") else {
            return .failure(TomlValueError(message: "unterminated array"))
        }
        let inner = s.dropFirst().dropLast()
        var parts: [String] = []
        var current = ""
        var depth = 0, inBasic = false, inLiteral = false
        var idx = inner.startIndex
        while idx < inner.endIndex {
            let c = inner[idx]
            if inBasic && c == "\\" {
                current.append(c)
                let next = inner.index(after: idx)
                if next < inner.endIndex {
                    current.append(inner[next])
                    idx = inner.index(after: next)
                } else {
                    idx = inner.endIndex
                }
                continue
            }
            if inBasic {
                if c == "\"" { inBasic = false }
            } else if inLiteral {
                if c == "'" { inLiteral = false }
            } else if c == "\"" {
                inBasic = true
            } else if c == "'" {
                inLiteral = true
            } else if c == "[" {
                depth += 1
            } else if c == "]" {
                depth -= 1
            } else if c == "," && depth == 0 {
                parts.append(current)
                current = ""
                idx = inner.index(after: idx)
                continue
            }
            current.append(c)
            idx = inner.index(after: idx)
        }
        parts.append(current)

        var values: [TomlValue] = []
        for (n, part) in parts.enumerated() {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if parts.count == 1 { return .success(.array([])) }   // empty array
                if n == parts.count - 1 { continue }                  // trailing comma
                return .failure(TomlValueError(message: "empty array element"))
            }
            switch parseValue(trimmed) {
            case .success(let value): values.append(value)
            case .failure(let error): return .failure(error)
            }
        }
        return .success(.array(values))
    }
}

// MARK: - Formation packages (docs/workflows-schema.md §Formation packages)

/// A valid, loadable formation package found under the workflows directory.
/// Holds only what the menu needs to render and launch; the orchestrator does
/// full validation and resolution at run time.
struct FormationPackage: Identifiable, Equatable {
    let id: String            // directory name
    let name: String
    let version: Int
    let description: String
    let roleCount: Int        // fixed roles only; a fan-out contributes no fixed count
    let phaseCount: Int       // 0 = single-phase [[role]] form
    let fanoutCeiling: Int?   // `max` of the first fan-out phase, if any
    let directoryURL: URL

    var manifestURL: URL { directoryURL.appendingPathComponent("formation.toml") }

    var menuDetail: String {
        let roles = roleCount == 1 ? "1 role" : "\(roleCount) roles"
        if phaseCount == 0 { return roles }
        var detail = "\(phaseCount) phases · \(roles)"
        if let ceiling = fanoutCeiling { detail += " · fan-out ≤ \(ceiling)" }
        return detail
    }
}

/// A directory under workflows/ that is not a loadable formation package.
/// Shown honestly in the menu rather than silently skipped.
struct FormationIssue: Identifiable, Equatable {
    let directoryName: String
    let message: String
    let directoryURL: URL

    var id: String { directoryName }
}

// MARK: - Launcher model

@MainActor
final class WorkflowLauncherModel: ObservableObject {

    @Published private(set) var packages: [FormationPackage] = []
    @Published private(set) var issues: [FormationIssue] = []
    /// False until the first scan lands — keeps "No Workflows Installed"
    /// from flashing for a frame in front of a populated directory.
    @Published private(set) var hasScanned = false
    /// Directory id of the package whose launch request is in flight, if any.
    /// While set, all menu items are disabled: two clicks must never mint two
    /// orchestrators for one gesture.
    @Published private(set) var launchInFlightID: String?
    @Published private(set) var outcome: LaunchOutcome?

    enum LaunchOutcome: Equatable {
        case launched(package: String, detail: String)
        case failed(package: String, detail: String)
    }

    /// Own client for one-shot requests, following the DaemonClient pattern:
    /// no subscribe stream, just request/response on a short-lived connection.
    /// Kept off AppModel so this feature touches no file outside its lane.
    private let client = DaemonClient()

    /// Where formation packages live. Mirrors the daemon's config-root rule
    /// ($XDG_CONFIG_HOME/focalpoint, else ~/.config/focalpoint).
    nonisolated static var workflowsDirectory: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("focalpoint/workflows", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".config/focalpoint/workflows", isDirectory: true)
    }

    /// The provider for the ONE agent the app launches: the formation's
    /// orchestrator. Claude Code, because the focalpoint-orchestrator skill
    /// currently ships as a Claude skill. Per-role provider choice stays with
    /// the orchestrator (spec §5.3); making this a Settings choice is deferred
    /// (see HANDOFF.md).
    private static let orchestratorProvider = "claude"

    // MARK: Scanning

    func refresh() {
        let directory = Self.workflowsDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.scan(directory: directory)
            Task { @MainActor [weak self] in
                self?.packages = result.packages
                self?.issues = result.issues
                self?.hasScanned = true
            }
        }
    }

    /// Filesystem scan + manifest load. Missing workflows directory means
    /// "nothing installed", not an error.
    nonisolated private static func scan(directory: URL)
        -> (packages: [FormationPackage], issues: [FormationIssue])
    {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], []) }

        var packages: [FormationPackage] = []
        var issues: [FormationIssue] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue   // stray files (READMEs, .DS_Store) are not packages
            }
            let dirName = entry.lastPathComponent
            let manifestURL = entry.appendingPathComponent("formation.toml")
            func issue(_ message: String) {
                issues.append(FormationIssue(directoryName: dirName, message: message, directoryURL: entry))
            }
            guard fm.fileExists(atPath: manifestURL.path) else {
                issue("missing formation.toml")
                continue
            }
            guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else {
                issue("formation.toml is not readable UTF-8")
                continue
            }
            switch TomlParser.parse(text) {
            case .failure(let error):
                issue("formation.toml line \(error.line): \(error.message)")
            case .success(let root):
                switch validateManifest(root: root, directory: entry) {
                case .failure(let error):
                    issue(error.message)
                case .success(let package):
                    packages.append(package)
                }
            }
        }
        return (packages, issues)
    }

    /// Schema-v1 checks for the fields the menu renders. Full validation
    /// (provider resolution, phase dependencies, containment paths) is the
    /// orchestrator's job; here we only accept what we can honestly display
    /// and launch, and report the rest as malformed.
    nonisolated private static func validateManifest(root: [String: TomlValue], directory: URL)
        -> Result<FormationPackage, ManifestInvalid>
    {
        func invalid(_ message: String) -> Result<FormationPackage, ManifestInvalid> {
            .failure(ManifestInvalid(message: message))
        }
        guard case .table(let formation)? = root["formation"] else {
            return invalid("missing [formation] table")
        }
        guard case .string(let name)? = formation["name"], !name.isEmpty else {
            return invalid("[formation] requires a nonempty name")
        }
        guard case .int(let version)? = formation["version"] else {
            return invalid("[formation] requires an integer version")
        }
        guard version == 1 else {
            return invalid("unsupported schema version \(version)")
        }
        guard case .string(let description)? = formation["description"], !description.isEmpty else {
            return invalid("[formation] requires a description")
        }

        func checkRole(_ role: [String: TomlValue], context: String) -> String? {
            guard case .string(let roleName)? = role["name"], !roleName.isEmpty else {
                return "\(context): role requires a nonempty name"
            }
            guard case .string(let type)? = role["type"], !type.isEmpty else {
                return "\(context) '\(roleName)': role requires a type"
            }
            return nil
        }

        var roleCount = 0
        var phaseCount = 0
        var fanoutCeiling: Int?

        let hasRoles = root["role"] != nil
        let hasPhases = root["phase"] != nil
        if hasRoles && hasPhases {
            return invalid("mixes [[role]] and [[phase]]; use exactly one form")
        }
        if hasRoles {
            guard case .tableArray(let roles)? = root["role"] else {
                return invalid("[[role]] must be an array of tables")
            }
            for role in roles {
                if let error = checkRole(role, context: "[[role]]") { return invalid(error) }
            }
            roleCount = roles.count
        } else if hasPhases {
            guard case .tableArray(let phases)? = root["phase"] else {
                return invalid("[[phase]] must be an array of tables")
            }
            phaseCount = phases.count
            for phase in phases {
                guard case .string(let phaseName)? = phase["name"], !phaseName.isEmpty else {
                    return invalid("[[phase]] requires a nonempty name")
                }
                if let rolesValue = phase["role"] {
                    guard case .tableArray(let roles) = rolesValue else {
                        return invalid("phase '\(phaseName)': [[phase.role]] must be an array of tables")
                    }
                    for role in roles {
                        if let error = checkRole(role, context: "phase '\(phaseName)'") {
                            return invalid(error)
                        }
                    }
                    roleCount += roles.count
                }
                if let fanoutValue = phase["fanout"] {
                    guard case .table(let fanout) = fanoutValue else {
                        return invalid("phase '\(phaseName)': [phase.fanout] must be a table")
                    }
                    guard case .int(let max)? = fanout["max"], max > 0 else {
                        return invalid("phase '\(phaseName)': fan-out requires a positive integer max")
                    }
                    if fanoutCeiling == nil { fanoutCeiling = max }
                }
            }
        } else {
            return invalid("no [[role]] or [[phase]] entries")
        }

        guard case .table(let escalate)? = root["escalate"] else {
            return invalid("missing [escalate] table")
        }
        guard case .array(let kinds)? = escalate["channel_kinds"], !kinds.isEmpty else {
            return invalid("[escalate] requires a nonempty channel_kinds list")
        }
        guard case .array(let states)? = escalate["states"], !states.isEmpty else {
            return invalid("[escalate] requires a nonempty states list")
        }
        guard case .string(let completion)? = escalate["completion"], !completion.isEmpty else {
            return invalid("[escalate] requires a completion policy")
        }

        return .success(FormationPackage(
            id: directory.lastPathComponent,
            name: name,
            version: version,
            description: description,
            roleCount: roleCount,
            phaseCount: phaseCount,
            fanoutCeiling: fanoutCeiling,
            directoryURL: directory
        ))
    }

    // MARK: Launching

    /// Start one formation: launch its orchestrator via the daemon's
    /// `launch-session` primitive (PROTOCOL.md §3/§4). Everything after this —
    /// validation, per-role providers, worktree prep, channel creation, the
    /// fan-out gates — happens inside that orchestrator agent. The app never
    /// sees or re-creates any of it.
    ///
    /// `targetCwd` is where the formation runs (spec §8.2's "against the auth
    /// refactor"): the menu shows it as "Runs in …" before anything launches,
    /// and the task text tells the orchestrator to confirm it with the human
    /// if the formation plainly targets something else.
    func start(_ package: FormationPackage, targetCwd: String) {
        guard launchInFlightID == nil else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetCwd, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            outcome = .failed(package: package.name,
                              detail: "Target directory no longer exists: \(targetCwd)")
            return
        }
        launchInFlightID = package.id
        outcome = nil

        let taskID = Self.mintTaskID(for: package)
        let request: [String: Any] = [
            "cmd": "launch-session",
            "provider": Self.orchestratorProvider,
            "cwd": targetCwd,
            "task": Self.orchestratorTask(for: package, targetCwd: targetCwd),
            "task_id": taskID,
            "title": "\(package.name) orchestrator",
            "role": "orchestrator",
        ]
        log("workflow launch requested package=\(boundedLogField(package.name)) task_id=\(boundedLogField(taskID)) provider=\(Self.orchestratorProvider) cwd=\(boundedLogField(targetCwd))")

        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The daemon replies on terminal-open acceptance, which is quick;
            // crew expansion is the orchestrator's asynchronous business and
            // is NOT awaited here.
            let response = client.request(request, timeout: 5)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.launchInFlightID = nil
                if let response, response["ok"] as? Bool == true {
                    let slot = (response["slot"] as? NSNumber)?.intValue
                    let detail = slot.map { "orchestrator opening on key \($0)" }
                        ?? "orchestrator session opening"
                    self.outcome = .launched(package: package.name, detail: detail)
                    log("workflow launch accepted package=\(boundedLogField(package.name)) slot=\(slot.map(String.init) ?? "-")")
                    // The session row itself is the durable confirmation; the
                    // transient note clears once the row has had time to appear.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                        guard let self,
                              case .launched(let name, _) = self.outcome,
                              name == package.name else { return }
                        self.outcome = nil
                    }
                } else {
                    let message = (response?["error"] as? String)
                        ?? "Could not reach the FocalPoint daemon."
                    self.outcome = .failed(package: package.name,
                                           detail: String(message.prefix(240)))
                    log("workflow launch failed package=\(boundedLogField(package.name)) error=\(boundedLogField(message))")
                }
            }
        }
    }

    func dismissOutcome() { outcome = nil }

    /// Stable task id for this run of the formation: unique per run (each run
    /// is a distinct crew, and grouping keys on the orchestrator's task id),
    /// within the daemon's 1–64 char / [A-Za-z0-9._-] rule. The in-flight
    /// guard above, not id reuse, is the double-click protection.
    private static func mintTaskID(for package: FormationPackage) -> String {
        let sanitized = package.name.map { c -> Character in
            (c.isASCII && (c.isLetter || c.isNumber) || c == "." || c == "_" || c == "-") ? c : "-"
        }
        let base = String(String(sanitized).prefix(40))
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return "wf-\(base)-\(suffix)"
    }

    /// The typed instruction §8.2 is a shortcut for: "run this formation".
    /// Expansion judgment is delegated wholesale to the orchestrator agent;
    /// the task names the manifest, the target, and the rules, nothing more.
    private static func orchestratorTask(for package: FormationPackage, targetCwd: String) -> String {
        """
        Run the FocalPoint formation "\(package.name)". Manifest: \(package.manifestURL.path). Agent types live in ~/.config/focalpoint/agents/.

        The human started this run from the FocalPoint app; that click is your authorization for the formation itself. Target directory: \(targetCwd) — the workspace in focus when the run was started. If the formation plainly targets something else, confirm with the human before preparing directories.

        You are this formation's orchestrator (launched role=orchestrator; your stable task id is in the launch preamble). Work the focalpoint-orchestrator skill end to end:
        1. Validate the manifest and resolve every role's agent type to an explicit provider; refuse on ambiguity rather than guessing.
        2. Prepare each role's working directory, wait for your own attachment to verify, then create the crew channel.
        3. Launch each role with fpctl-agent launch --role worker --manager-task-id <your task id> --channel <id>, and wait for verified attachments.
        4. Honor every phase gate: never auto-approve, never silently retry, and on partial failure report to the human instead of stopping successful roles.

        The daemon validates individual launch/channel/stop calls only; all expansion judgment is yours.
        """
    }

    // MARK: Folder conveniences

    /// Open the workflows directory in Finder, creating it first if needed so
    /// the empty state has somewhere real to point at.
    func openWorkflowsFolder() {
        let directory = Self.workflowsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSWorkspace.shared.open(directory)
    }

    func reveal(_ issue: FormationIssue) {
        NSWorkspace.shared.activateFileViewerSelecting([issue.directoryURL])
    }
}

// MARK: - Menu-bar section view

/// The "Start Workflow" row of the dropdown panel: a submenu listing the
/// installed formations, plus honest inline status (offline, launching,
/// launch failed, malformed packages). Visual language matches the rest of
/// MenuContentView: Metrics.hPad margins, caption/callout type, footer-style
/// borderless controls.
struct WorkflowLauncherSection: View {
    @ObservedObject var launcher: WorkflowLauncherModel
    let daemonConnected: Bool
    /// Where a started formation runs — resolved by the parent from the
    /// focused/most-recent session, shown in the menu before launch.
    let targetCwd: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                startMenu
                if !daemonConnected {
                    Text("Daemon offline")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if !launcher.issues.isEmpty {
                    Label("\(launcher.issues.count)", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help(launcher.issues
                            .map { "\($0.directoryName): \($0.message)" }
                            .joined(separator: "\n"))
                }
            }
            if let launchingName {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text("Launching \(launchingName) orchestrator\u{2026}")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let outcome = launcher.outcome {
                outcomeLine(outcome)
            }
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 8)
        .onAppear { launcher.refresh() }
    }

    private var launchingName: String? {
        guard let id = launcher.launchInFlightID else { return nil }
        return launcher.packages.first(where: { $0.id == id })?.name ?? id
    }

    private var startMenu: some View {
        Menu {
            menuContent
        } label: {
            Label("Start Workflow", systemImage: "person.3.sequence")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .font(.callout)
        .help(daemonConnected
              ? "Launch one orchestrator agent for an installed formation — the orchestrator expands and runs the crew"
              : "The daemon is offline, so workflows can't be launched — installed packages are still listed")
    }

    @ViewBuilder
    private var menuContent: some View {
        Text("Runs in \(Self.shortPath(URL(fileURLWithPath: targetCwd)))")
            .lineLimit(1)
            .truncationMode(.middle)
        if !launcher.hasScanned {
            Text("Scanning\u{2026}")
        } else if launcher.packages.isEmpty && launcher.issues.isEmpty {
            Text("No Workflows Installed")
            Text("Add a formation package to \(Self.shortPath(WorkflowLauncherModel.workflowsDirectory))")
        } else {
            ForEach(launcher.packages) { package in
                Button {
                    launcher.start(package, targetCwd: targetCwd)
                } label: {
                    Label("\(package.name) · \(package.menuDetail)",
                          systemImage: "person.3.sequence")
                }
                .disabled(!daemonConnected || launcher.launchInFlightID != nil)
            }
            if !launcher.issues.isEmpty {
                Divider()
                ForEach(launcher.issues) { issue in
                    Button {
                        launcher.reveal(issue)
                    } label: {
                        Label("\(issue.directoryName): \(issue.message)",
                              systemImage: "exclamationmark.triangle")
                    }
                }
            }
            if !daemonConnected {
                Divider()
                Text("Daemon Offline — Start Unavailable")
            }
        }
        Divider()
        Button("Refresh") { launcher.refresh() }
        Button("Open Workflows Folder\u{2026}") { launcher.openWorkflowsFolder() }
        Button("Workflow Editor\u{2026}") { WorkflowEditorWindow.shared.show() }
    }

    @ViewBuilder
    private func outcomeLine(_ outcome: WorkflowLauncherModel.LaunchOutcome) -> some View {
        switch outcome {
        case .launched(let name, let detail):
            Label("\(name): \(detail)", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .failed(let name, let detail):
            HStack(alignment: .top, spacing: 5) {
                Label("\(name): \(detail)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                Spacer(minLength: 2)
                Button { launcher.dismissOutcome() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
    }

    private static func shortPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
