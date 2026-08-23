// FocalPoint menu-bar app — workflow launcher (WORKFLOWS-PROPOSAL.md §8.2).
//
// Lists formation packages installed under ~/.config/focalpoint/workflows/
// and starts one. The architectural boundary is deliberate and load-bearing:
// the app CANNOT run a formation itself. It launches exactly ONE agent — the
// formation's orchestrator — via the daemon's `launch-session` primitive, and
// that orchestrator validates, expands, and sequences the crew (spec §3, §5.2).
// The app never expands a manifest into launch calls and never creates
// channels. Preflight records explicit provider/model choices as reviewed data;
// the orchestrator revalidates and materializes them through current APIs.
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
/// The validated data the menu and preflight need to render an honest launch
/// review. The orchestrator repeats validation at materialization time.
struct FormationPackage: Identifiable, Equatable {
    let id: String            // directory name
    let name: String
    let version: Int
    let description: String
    let roleCount: Int        // fixed roles only; a fan-out contributes no fixed count
    let phaseCount: Int       // 0 = single-phase [[role]] form
    let fanoutCeiling: Int?   // `max` of the first fan-out phase, if any
    let roles: [FormationRoleSummary]
    let phases: [FormationPhaseSummary]
    let escalationKinds: [String]
    let escalationStates: [String]
    let completionPolicy: String
    let directoryURL: URL

    var manifestURL: URL { directoryURL.appendingPathComponent("formation.toml") }

    var menuDetail: String {
        let roles = roleCount == 1 ? "1 role" : "\(roleCount) roles"
        if phaseCount == 0 { return roles }
        var detail = "\(phaseCount) phases · \(roles)"
        if let ceiling = fanoutCeiling { detail += " · fan-out ≤ \(ceiling)" }
        return detail
    }

    var allRoles: [FormationRoleSummary] {
        phases.isEmpty ? roles : phases.flatMap(\.roles)
    }

    var complexitySignals: WorkflowComplexitySignals {
        WorkflowComplexitySignals(
            fixedRoleCount: roleCount,
            phaseCount: phaseCount,
            fanoutCeiling: fanoutCeiling,
            confirmationGateCount: phases.filter { $0.gate == .confirm }.count
        )
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

    /// Installed agent types, sibling of `workflowsDirectory`.
    nonisolated static var agentsDirectory: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("focalpoint/agents", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".config/focalpoint/agents", isDirectory: true)
    }

    /// Non-nil when an agent type declares an `[enforced]` table, which the
    /// launch path cannot deliver — see the call site in `checkRole`.
    ///
    /// A missing or unreadable type file is *not* treated as a refusal here:
    /// the role's own `type` resolution is the orchestrator's job, and failing
    /// a formation because a type is not installed locally would be a
    /// different (and wrong) error. Only a type that is present and demands
    /// enforcement blocks the launch.
    nonisolated static func enforcedTierReason(forType type: String) -> String? {
        // Reject path separators before touching the filesystem: a type name
        // is a directory name under agentsDirectory, never a traversal.
        guard !type.contains("/"), type != "..", type != "." else {
            return "invalid agent type name '\(type)'"
        }
        let typeFile = agentsDirectory
            .appendingPathComponent(type, isDirectory: true)
            .appendingPathComponent("type.toml")
        guard let text = try? String(contentsOf: typeFile, encoding: .utf8) else { return nil }
        guard case .success(let root) = TomlParser.parse(text) else { return nil }
        guard case .table(let enforced)? = root["enforced"], !enforced.isEmpty else { return nil }
        let fields = enforced.keys.sorted().joined(separator: ", ")
        return "agent type '\(type)' declares [enforced] (\(fields)), which nothing delivers; "
             + "FocalPoint refuses rather than honoring it as prompt text only"
    }

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

    /// Deterministic schema-v1 checks needed for an honest preflight. Provider
    /// capability/enforcement checks are repeated by the orchestrator because
    /// the environment can change between review and materialization.
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

        func readRole(_ role: [String: TomlValue], context: String,
                      phaseName: String?, index: Int,
                      fanoutMaximum: Int? = nil) -> Result<FormationRoleSummary, ManifestInvalid> {
            guard case .string(let roleName)? = role["name"], !roleName.isEmpty else {
                return .failure(ManifestInvalid(message: "\(context): role requires a nonempty name"))
            }
            guard case .string(let type)? = role["type"], !type.isEmpty else {
                return .failure(ManifestInvalid(message: "\(context) '\(roleName)': role requires a type"))
            }
            // WORKFLOWS-PROPOSAL.md §4.2: `[enforced]` declares a guarantee
            // that prep must materialize through a provider's project-local
            // enforcement surface. Nothing does that yet — `launch-session`
            // carries only provider/model/cwd/task/identity/channel — so a
            // type declaring it would launch with the constraint honored as
            // prompt text alone. That is precisely the "looks sandboxed and
            // is not" failure the spec forbids, so refuse rather than
            // silently downgrade. Remove this check only together with
            // deterministic per-provider prep AND effective-setting
            // verification.
            if let reason = Self.enforcedTierReason(forType: type) {
                return .failure(ManifestInvalid(message: "\(context) '\(roleName)': \(reason)"))
            }
            let kind: String
            if let value = role["kind"] {
                guard case .string(let raw) = value, ["worker", "orchestrator"].contains(raw) else {
                    return .failure(ManifestInvalid(message: "\(context) '\(roleName)': kind must be worker or orchestrator"))
                }
                kind = raw
            } else {
                kind = "worker"
            }
            let prep: String?
            if let value = role["prep"] {
                guard case .string(let raw) = value, raw == "worktree" else {
                    return .failure(ManifestInvalid(message: "\(context) '\(roleName)': prep must be worktree"))
                }
                prep = raw
            } else { prep = nil }
            let task: String?
            if let value = role["task"] {
                guard case .string(let raw) = value, !raw.isEmpty else {
                    return .failure(ManifestInvalid(message: "\(context) '\(roleName)': task must be a nonempty string"))
                }
                task = raw
            } else { task = nil }
            return .success(FormationRoleSummary(
                id: "\(phaseName ?? "root"):\(roleName):\(index)", name: roleName,
                type: type, kind: kind, prep: prep, task: task,
                phaseName: phaseName, fanoutMaximum: fanoutMaximum
            ))
        }

        var roleCount = 0
        var phaseCount = 0
        var fanoutCeiling: Int?
        var roleSummaries: [FormationRoleSummary] = []
        var phaseSummaries: [FormationPhaseSummary] = []
        var declaredRoleNames: Set<String> = []

        let hasRoles = root["role"] != nil
        let hasPhases = root["phase"] != nil
        if hasRoles && hasPhases {
            return invalid("mixes [[role]] and [[phase]]; use exactly one form")
        }
        if hasRoles {
            guard case .tableArray(let roles)? = root["role"] else {
                return invalid("[[role]] must be an array of tables")
            }
            for (index, role) in roles.enumerated() {
                switch readRole(role, context: "[[role]]", phaseName: nil, index: index) {
                case .failure(let error): return .failure(error)
                case .success(let summary):
                    guard declaredRoleNames.insert(summary.name).inserted else {
                        return invalid("duplicate role name '\(summary.name)'")
                    }
                    roleSummaries.append(summary)
                }
            }
            roleCount = roles.count
        } else if hasPhases {
            guard case .tableArray(let phases)? = root["phase"] else {
                return invalid("[[phase]] must be an array of tables")
            }
            phaseCount = phases.count
            var earlierPhaseNames: Set<String> = []
            for (phaseIndex, phase) in phases.enumerated() {
                guard case .string(let phaseName)? = phase["name"], !phaseName.isEmpty else {
                    return invalid("[[phase]] requires a nonempty name")
                }
                guard !earlierPhaseNames.contains(phaseName) else {
                    return invalid("duplicate phase name '\(phaseName)'")
                }
                let after: String?
                if phaseIndex == 0 {
                    guard phase["after"] == nil else {
                        return invalid("phase '\(phaseName)': after is invalid on the first phase")
                    }
                    after = nil
                } else {
                    guard case .string(let raw)? = phase["after"],
                          !raw.isEmpty, earlierPhaseNames.contains(raw) else {
                        return invalid("phase '\(phaseName)': after must name an earlier phase")
                    }
                    after = raw
                }
                let effectiveGateValue = phase["gate"]
                let gate: FormationGateSummary
                if let gateValue = effectiveGateValue {
                    guard case .string(let raw) = gateValue,
                          let parsed = FormationGateSummary(rawValue: raw) else {
                        return invalid("phase '\(phaseName)': gate must be authorized, confirm, or auto")
                    }
                    gate = parsed
                } else if phase["fanout"] != nil {
                    gate = .confirm
                } else {
                    return invalid("phase '\(phaseName)': missing required gate")
                }
                var summaries: [FormationRoleSummary] = []
                if let rolesValue = phase["role"] {
                    guard case .tableArray(let roles) = rolesValue else {
                        return invalid("phase '\(phaseName)': [[phase.role]] must be an array of tables")
                    }
                    guard phase["fanout"] == nil else {
                        return invalid("phase '\(phaseName)' cannot contain both roles and fan-out")
                    }
                    for (roleIndex, role) in roles.enumerated() {
                        switch readRole(role, context: "phase '\(phaseName)'",
                                        phaseName: phaseName, index: roleIndex) {
                        case .failure(let error): return .failure(error)
                        case .success(let summary):
                            guard declaredRoleNames.insert(summary.name).inserted else {
                                return invalid("duplicate role name '\(summary.name)'")
                            }
                            summaries.append(summary)
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
                    guard case .string(let source)? = fanout["from"], !source.isEmpty,
                          case .string(let type)? = fanout["type"], !type.isEmpty,
                          case .string(let cwdRoot)? = fanout["cwd_root"], !cwdRoot.isEmpty else {
                        return invalid("phase '\(phaseName)': fan-out requires from, type, and cwd_root")
                    }
                    guard declaredRoleNames.contains(source) else {
                        return invalid("phase '\(phaseName)': fan-out source '\(source)' must be a role in an earlier phase")
                    }
                    guard !cwdRoot.hasPrefix("/"),
                          !cwdRoot.split(separator: "/").contains("..") else {
                        return invalid("phase '\(phaseName)': fan-out cwd_root must be relative without traversal")
                    }
                    if let reason = Self.enforcedTierReason(forType: type) {
                        return invalid("phase '\(phaseName)' fan-out: \(reason)")
                    }
                    // A fan-out phase means an agent-authored plan decides how
                    // many processes launch and what they are told to do, so
                    // the human must confirm the resolved list first
                    // (WORKFLOWS-PROPOSAL.md §6.1). `gate = "auto"` is only
                    // defensible where no new authority appears — never here.
                    //
                    // This check is deterministic and lives in the launch path
                    // on purpose. packages/validate.sh already enforces it,
                    // but that script is not installed anywhere the app can
                    // rely on, and delegating the rule to the orchestrator's
                    // prompt would leave an instruction to a language model as
                    // the only thing between a crafted manifest and
                    // plan-authored process creation.
                    if gate != .confirm {
                        return invalid("phase '\(phaseName)': fan-out requires gate = \"confirm\" (got \"\(gate.rawValue)\")")
                    }
                    if fanoutCeiling == nil { fanoutCeiling = max }
                    summaries.append(FormationRoleSummary(
                        id: "\(phaseName):fanout:\(phaseIndex)", name: "Slices from \(source)",
                        type: type, kind: "worker", prep: "\(cwdRoot) worktrees", task: nil,
                        phaseName: phaseName, fanoutMaximum: max
                    ))
                }
                guard !summaries.isEmpty else {
                    return invalid("phase '\(phaseName)' requires roles or fan-out")
                }
                phaseSummaries.append(FormationPhaseSummary(
                    id: "\(phaseName):\(phaseIndex)", name: phaseName, after: after,
                    gate: gate, roles: summaries
                ))
                earlierPhaseNames.insert(phaseName)
            }
        } else {
            return invalid("no [[role]] or [[phase]] entries")
        }

        guard case .table(let escalate)? = root["escalate"] else {
            return invalid("missing [escalate] table")
        }
        // Vocabulary is pinned, not merely nonempty. An unrecognized value
        // used to validate clean, which meant a manifest could quietly opt out
        // of surfacing the states the device exists to show.
        let allowedKinds: Set<String> = ["note", "question", "progress", "blocker", "directive"]
        guard case .array(let kinds)? = escalate["channel_kinds"], !kinds.isEmpty else {
            return invalid("[escalate] requires a nonempty channel_kinds list")
        }
        for kind in kinds {
            guard case .string(let value) = kind, allowedKinds.contains(value) else {
                return invalid("[escalate] unknown channel kind; allowed: \(allowedKinds.sorted().joined(separator: ", "))")
            }
        }

        let allowedStates: Set<String> = ["error", "approval", "waiting", "running",
                                          "thinking", "done", "compacting", "idle"]
        guard case .array(let states)? = escalate["states"], !states.isEmpty else {
            return invalid("[escalate] requires a nonempty states list")
        }
        var declaredStates: Set<String> = []
        var escalationStates: [String] = []
        for state in states {
            guard case .string(let value) = state, allowedStates.contains(value) else {
                return invalid("[escalate] unknown state; allowed: \(allowedStates.sorted().joined(separator: ", "))")
            }
            declaredStates.insert(value)
            escalationStates.append(value)
        }
        // `error` and `approval` visibility is not a manifest's decision. A
        // formation that omits them is asking to hide the two states a human
        // must act on — the whole reason the device exists.
        let mandatory = ["error", "approval"].filter { !declaredStates.contains($0) }
        if !mandatory.isEmpty {
            return invalid("[escalate] states must include \(mandatory.joined(separator: " and "))")
        }

        let allowedCompletion: Set<String> = ["all-roles-done", "all-phases-done", "manual"]
        guard case .string(let completion)? = escalate["completion"],
              allowedCompletion.contains(completion) else {
            return invalid("[escalate] completion must be one of \(allowedCompletion.sorted().joined(separator: ", "))")
        }

        return .success(FormationPackage(
            id: directory.lastPathComponent,
            name: name,
            version: version,
            description: description,
            roleCount: roleCount,
            phaseCount: phaseCount,
            fanoutCeiling: fanoutCeiling,
            roles: roleSummaries,
            phases: phaseSummaries,
            escalationKinds: kinds.compactMap { if case .string(let value) = $0 { value } else { nil } },
            escalationStates: escalationStates,
            completionPolicy: completion,
            directoryURL: directory
        ))
    }

    // MARK: Launching

    /// Start one formation: launch its orchestrator via the daemon's
    /// `launch-session` primitive (PROTOCOL.md §3/§4). Everything after this —
    /// revalidation, worktree prep, channel creation, role launch calls, and
    /// fan-out gates — happens inside that orchestrator agent. The app passes
    /// reviewed assignments but never expands them into launch calls itself.
    ///
    /// The configuration comes only from the explicit preflight. In
    /// particular, cwd/provider/model are concrete values; this method never
    /// consults focused-session or last-used defaults.
    func start(_ package: FormationPackage, configuration: WorkflowLaunchConfiguration) {
        guard launchInFlightID == nil else { return }
        let targetCwd = configuration.projectDirectory.path
        let configurationErrors = WorkflowPreflightValidation.errors(
            projectDirectory: configuration.projectDirectory,
            orchestratorModel: configuration.orchestratorModel,
            assignments: configuration.roleAssignments,
            fanoutLimit: configuration.fanoutLimit,
            fanoutCeiling: package.fanoutCeiling,
            unresolvedTypes: []
        )
        guard configurationErrors.isEmpty else {
            outcome = .failed(package: package.name, detail: configurationErrors.joined(separator: " "))
            return
        }
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
            "agent_type": "workflow-orchestrator",
            "provider": configuration.orchestratorProvider.rawValue,
            "model": configuration.orchestratorModel,
            "cwd": targetCwd,
            "task": Self.orchestratorTask(for: package, configuration: configuration),
            "task_id": taskID,
            "title": "\(package.name) orchestrator",
            "role": "orchestrator",
            "workflow_id": package.id,
            "workflow_run_id": taskID,
            "workflow_phase": "orchestration",
            "workflow_gate": "authorized",
            "workflow_fanout": false,
        ]
        log("workflow launch requested package=\(boundedLogField(package.name)) task_id=\(boundedLogField(taskID)) provider=\(configuration.orchestratorProvider.rawValue) model=\(boundedLogField(configuration.orchestratorModel)) cwd=\(boundedLogField(targetCwd))")

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
    private static func orchestratorTask(for package: FormationPackage,
                                         configuration: WorkflowLaunchConfiguration) -> String {
        let assignments = configuration.roleAssignments.map { assignment in
            let phase = assignment.phaseName.map { " phase=\($0)" } ?? ""
            return "- \(assignment.roleName) [type=\(assignment.typeName)\(phase)]: provider=\(assignment.provider.rawValue), model=\(assignment.model)"
        }.joined(separator: "\n")
        let fanout = configuration.fanoutLimit.map {
            "The human set a dynamic fan-out limit of \($0), which may only reduce the manifest ceiling."
        } ?? "This formation has no dynamic fan-out override."
        return """
        Run the FocalPoint formation "\(package.name)". Manifest: \(package.manifestURL.path). Agent types live in ~/.config/focalpoint/agents/.

        The human explicitly selected and finally confirmed target directory: \(configuration.projectDirectory.path). The preflight classified this formation as \(configuration.complexity.rawValue) complexity. Do not substitute a focused directory or last-used provider/model.

        The human reviewed these explicit role assignments:
        \(assignments)
        \(fanout)

        You are this formation's orchestrator (launched role=orchestrator; your stable task id is in the launch preamble). Work the focalpoint-orchestrator skill end to end:
        1. Revalidate the manifest and agent types, then use the explicit provider/model assignments above; refuse if a provider cannot deliver a declared capability or enforcement constraint.
        2. Prepare each role's working directory, wait for your own attachment to verify, then create the crew channel.
        3. Launch each role with fpctl-agent launch --role worker --manager-task-id <your task id> --channel <id>, and wait for verified attachments.
        4. Honor every phase gate. The final preflight authorized only the formation and phases marked authorized; it did not pre-approve confirm gates. Never auto-approve, never silently retry, and on partial failure report to the human instead of stopping successful roles.

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
    /// A convenience displayed in preflight only. It is never selected unless
    /// the human explicitly presses "Select This Folder".
    let targetCwd: String
    @State private var preflightPackage: FormationPackage?

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
        .sheet(item: $preflightPackage) { package in
            WorkflowLaunchPreflightView(
                package: package,
                suggestedDirectory: URL(fileURLWithPath: targetCwd, isDirectory: true),
                daemonConnected: daemonConnected
            ) { configuration in
                launcher.start(package, configuration: configuration)
            }
        }
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
        Text("Project folder is chosen in preflight")
        if !launcher.hasScanned {
            Text("Scanning\u{2026}")
        } else if launcher.packages.isEmpty && launcher.issues.isEmpty {
            Text("No Workflows Installed")
            Text("Add a formation package to \(Self.shortPath(WorkflowLauncherModel.workflowsDirectory))")
        } else {
            ForEach(launcher.packages) { package in
                Button {
                    preflightPackage = package
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
