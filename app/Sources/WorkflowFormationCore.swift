// FocalPoint menu-bar app — formation manifest parsing and validation core.
//
// This file deliberately uses Foundation only so manifest handling can be
// tested without launching the app or consulting a real user configuration.
// It was extracted from WorkflowLauncher.swift so the workflow graph model
// tests can load the bundled catalog through the exact same parser and
// validator the launcher trusts. The schema's narrow slice of TOML (tables,
// arrays of tables, strings, integers, booleans, and string arrays — see
// docs/workflows-schema.md) is parsed by the small subset parser below;
// swiftc-only build means no package dependencies.
// MIT License.

import Foundation

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
struct ManifestInvalid: Error {
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

    /// Fixed roles and bounded fan-out types referenced by this formation.
    var referencedAgentTypes: [String] {
        Array(Set(allRoles.map(\.type))).sorted()
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

// MARK: - Schema-v1 validation

enum FormationManifestValidator {

    /// Deterministic schema-v1 checks needed for an honest preflight. Provider
    /// capability/enforcement checks are repeated by the orchestrator because
    /// the environment can change between review and materialization.
    ///
    /// `enforcedTierReason` maps an agent-type name to a refusal reason when
    /// that type declares an `[enforced]` table the launch path cannot
    /// deliver. The launcher passes its filesystem-backed check; tests inject
    /// a stub so results never depend on the host's real configuration.
    static func validate(root: [String: TomlValue], directory: URL,
                         enforcedTierReason: (String) -> String?)
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
        guard (1...2).contains(version) else {
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
            if let reason = enforcedTierReason(type) {
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
                phaseName: phaseName, fanoutMaximum: fanoutMaximum, fanoutSource: nil
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
                    if let reason = enforcedTierReason(type) {
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
                        phaseName: phaseName, fanoutMaximum: max, fanoutSource: source
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
}
