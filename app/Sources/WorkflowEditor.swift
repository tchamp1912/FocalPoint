// FocalPoint menu-bar app — workflow editor (model layer).
//
// Edits the two package kinds the launcher runs: formation packages
// (~/.config/focalpoint/workflows/<name>/formation.toml) and agent-type
// packages (~/.config/focalpoint/agents/<name>/type.toml + persona file).
// Schema: docs/workflows-schema.md. The editor is a *client of the same
// files*, not a new source of truth — packages stay inert, untrusted data
// and saving one never launches anything.
//
// Save is a canonical TOML rewrite from the edited model, not a targeted
// patch: the schema's narrow slice makes regeneration safe and predictable,
// but hand-written comments and unknown fields in an edited manifest are
// dropped. Unknown fields are surfaced as load warnings so that loss is
// never silent.
// MIT License.

import SwiftUI
import AppKit
import Combine

// MARK: - Editable models (value types; dirty = model != loaded snapshot)

/// The human gate at a phase transition (docs/workflows-schema.md §Phases,
/// WORKFLOWS-PROPOSAL.md §5.3/§6.3). The summaries are shown verbatim in the
/// UI — they are the honest contract of what each choice does.
enum PhaseGate: String, CaseIterable, Identifiable {
    case authorized, confirm, auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .authorized: return "Authorized"
        case .confirm:    return "Confirm"
        case .auto:       return "Auto"
        }
    }

    var summary: String {
        switch self {
        case .authorized:
            return "Runs under the human's initial go-ahead — no extra prompt."
        case .confirm:
            return "The orchestrator presents the resolved crew and waits for the human before launching."
        case .auto:
            return "No human prompt. Defensible only where the phase adds no new authority: fixed roles, fixed types, no plan-authored task text."
        }
    }
}

enum RoleKind: String, CaseIterable, Identifiable {
    case worker, orchestrator
    var id: String { rawValue }
}

struct EditableRole: Identifiable, Equatable {
    let id: UUID
    var name = ""
    var type = ""
    var kind: RoleKind = .worker
    var prep = ""   // "" = none; schema v1 accepts only "worktree"
    var task = ""   // "" = no fixed task text
}

struct EditableFanout: Equatable {
    var from = ""
    var max = 4
    var type = ""
    var cwdRoot = "worktrees/"
}

struct EditablePhase: Identifiable, Equatable {
    let id: UUID
    var name = ""
    var after: String? = nil
    var gate: PhaseGate = .authorized
    var useFanout = false
    var roles: [EditableRole] = []
    var fanout = EditableFanout()
}

struct EditableEscalate: Equatable {
    var channelKinds: [String] = ["blocker"]
    var states: [String] = ["error", "approval"]
    var completion = "all-roles-done"
}

struct EditableFormation: Identifiable, Equatable {
    let id: String            // directory name — the package's stable identity
    var directoryURL: URL
    var name = ""
    var version = 1
    var description = ""
    var phased = false        // false = single-phase [[role]] form
    var roles: [EditableRole] = []
    var phases: [EditablePhase] = []
    var escalate = EditableEscalate()
    /// Non-blocking load notes (unknown fields that a save would drop).
    var warnings: [String] = []
}

struct EditableAgentType: Identifiable, Equatable {
    let id: String            // directory name
    var directoryURL: URL
    var name = ""
    var version = 1
    var description = ""
    var prefer: [String] = ["claude"]
    var model = ""            // "" = selected provider's default
    var requires: [String] = []
    var personaTitle = ""
    var personaPromptFile = "persona.md"
    var advisoryScope = ""
    var advisoryOutput = ""
    var advisoryEscalateAs = ""
    var enforcedReadOnly = false
    var allowPaths: [String] = []
    var personaMarkdown = ""
    var warnings: [String] = []
}

/// A package directory that failed to load. Shown in the sidebar with the
/// reason rather than silently skipped — same honesty rule as the launcher.
struct BrokenPackage: Identifiable, Equatable {
    enum Kind: String { case formation, agentType }
    let id: String            // directory name
    let kind: Kind
    let directoryURL: URL
    let message: String
}

enum EditorSelection: Hashable {
    case formation(String)
    case agentType(String)
    case bundledFormation(String)
    case bundledAgentType(String)
    case broken(BrokenPackage.Kind, String)
}

extension EditableFormation {
    /// Fixed roles and bounded fan-out types are both dependencies of a
    /// formation. This is planning data only; it never expands fan-out.
    var referencedAgentTypes: [String] {
        let fixed = phased ? phases.flatMap { $0.roles.map(\.type) } : roles.map(\.type)
        let fanout = phased ? phases.filter(\.useFanout).map { $0.fanout.type } : []
        return Array(Set((fixed + fanout).filter { !$0.isEmpty })).sorted()
    }
}

/// Load result for one package. Not Swift.Result: its Failure must conform
/// to Error, and a plain String reason is all these loaders ever produce.
enum PackageLoad<Payload> {
    case loaded(Payload)
    case failed(String)
}

// MARK: - TOML read helpers (file-private; shared by both loaders)

private enum TomlRead {
    static func str(_ table: [String: TomlValue], _ key: String) -> String? {
        guard case .string(let value)? = table[key] else { return nil }
        return value
    }

    static func int(_ table: [String: TomlValue], _ key: String) -> Int? {
        guard case .int(let value)? = table[key] else { return nil }
        return value
    }

    static func stringList(_ table: [String: TomlValue], _ key: String) -> [String]? {
        guard case .array(let items)? = table[key] else { return nil }
        var out: [String] = []
        for item in items {
            guard case .string(let value) = item else { return nil }
            out.append(value)
        }
        return out
    }

    static func unknownFields(_ table: [String: TomlValue], known: Set<String>,
                              context: String, into warnings: inout [String]) {
        for key in table.keys.sorted() where !known.contains(key) {
            warnings.append("\(context): unknown field '\(key)' — not editable here; saving rewrites the file without it")
        }
    }
}

// MARK: - Formation loader

enum FormationLoader {
    static func load(directory: URL) -> PackageLoad<EditableFormation> {
        let manifestURL = directory.appendingPathComponent("formation.toml")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return .failed("missing formation.toml")
        }
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            return .failed("formation.toml is not readable UTF-8")
        }
        switch TomlParser.parse(text) {
        case .failure(let error):
            return .failed("formation.toml line \(error.line): \(error.message)")
        case .success(let root):
            return extract(root: root, directory: directory)
        }
    }

    private static func extract(root: [String: TomlValue], directory: URL)
        -> PackageLoad<EditableFormation>
    {
        var warnings: [String] = []
        var formation = EditableFormation(id: directory.lastPathComponent, directoryURL: directory)

        guard case .table(let header)? = root["formation"] else {
            return .failed("missing [formation] table")
        }
        TomlRead.unknownFields(header, known: ["name", "version", "description"],
                               context: "[formation]", into: &warnings)
        guard let name = TomlRead.str(header, "name"), !name.isEmpty else {
            return .failed("[formation] requires a nonempty name")
        }
        guard let version = TomlRead.int(header, "version") else {
            return .failed("[formation] requires an integer version")
        }
        guard (1...2).contains(version) else {
            return .failed("unsupported schema version \(version)")
        }
        guard let description = TomlRead.str(header, "description"), !description.isEmpty else {
            return .failed("[formation] requires a description")
        }
        formation.name = name
        formation.version = version
        formation.description = description

        let hasRoles = root["role"] != nil
        let hasPhases = root["phase"] != nil
        if hasRoles && hasPhases {
            return .failed("mixes [[role]] and [[phase]]; a manifest uses exactly one form")
        }
        if hasRoles {
            guard case .tableArray(let roles)? = root["role"] else {
                return .failed("[[role]] must be an array of tables")
            }
            formation.phased = false
            for table in roles {
                switch extractRole(table, context: "[[role]]", warnings: &warnings) {
                case .failed(let message): return .failed(message)
                case .loaded(let role): formation.roles.append(role)
                }
            }
        } else if hasPhases {
            guard case .tableArray(let phases)? = root["phase"] else {
                return .failed("[[phase]] must be an array of tables")
            }
            formation.phased = true
            for table in phases {
                switch extractPhase(table, warnings: &warnings) {
                case .failed(let message): return .failed(message)
                case .loaded(let phase): formation.phases.append(phase)
                }
            }
        } else {
            return .failed("no [[role]] or [[phase]] entries")
        }

        guard case .table(let escalate)? = root["escalate"] else {
            return .failed("missing [escalate] table")
        }
        TomlRead.unknownFields(escalate, known: ["channel_kinds", "states", "completion"],
                               context: "[escalate]", into: &warnings)
        guard let kinds = TomlRead.stringList(escalate, "channel_kinds"), !kinds.isEmpty else {
            return .failed("[escalate] requires a nonempty channel_kinds list")
        }
        guard let states = TomlRead.stringList(escalate, "states"), !states.isEmpty else {
            return .failed("[escalate] requires a nonempty states list")
        }
        guard let completion = TomlRead.str(escalate, "completion"), !completion.isEmpty else {
            return .failed("[escalate] requires a completion policy")
        }
        formation.escalate = EditableEscalate(channelKinds: kinds, states: states,
                                              completion: completion)

        for key in root.keys.sorted()
        where !["formation", "role", "phase", "escalate"].contains(key) {
            warnings.append("unknown table '\(key)' — saving rewrites the manifest without it")
        }
        formation.warnings = warnings
        return .loaded(formation)
    }

    private static func extractRole(_ table: [String: TomlValue], context: String,
                                    warnings: inout [String]) -> PackageLoad<EditableRole> {
        guard let name = TomlRead.str(table, "name"), !name.isEmpty else {
            return .failed("\(context): role requires a nonempty name")
        }
        guard let type = TomlRead.str(table, "type"), !type.isEmpty else {
            return .failed("\(context) '\(name)': role requires a type")
        }
        var kind: RoleKind = .worker
        if let raw = TomlRead.str(table, "kind") {
            guard let parsed = RoleKind(rawValue: raw) else {
                return .failed("\(context) '\(name)': unknown kind '\(raw)' (worker or orchestrator)")
            }
            kind = parsed
        }
        var prep = ""
        if let raw = TomlRead.str(table, "prep") {
            guard raw == "worktree" else {
                return .failed("\(context) '\(name)': schema v1 only accepts prep = \"worktree\"")
            }
            prep = raw
        }
        TomlRead.unknownFields(table, known: ["name", "type", "kind", "prep", "task"],
                               context: "\(context) '\(name)'", into: &warnings)
        return .loaded(EditableRole(id: UUID(), name: name, type: type, kind: kind,
                                    prep: prep, task: TomlRead.str(table, "task") ?? ""))
    }

    private static func extractPhase(_ table: [String: TomlValue],
                                     warnings: inout [String]) -> PackageLoad<EditablePhase> {
        guard let name = TomlRead.str(table, "name"), !name.isEmpty else {
            return .failed("[[phase]] requires a nonempty name")
        }
        let context = "phase '\(name)'"
        TomlRead.unknownFields(table, known: ["name", "after", "gate", "role", "fanout"],
                               context: context, into: &warnings)
        var phase = EditablePhase(id: UUID(), name: name)
        phase.after = TomlRead.str(table, "after")

        let hasRoles = table["role"] != nil
        let hasFanout = table["fanout"] != nil
        if hasRoles && hasFanout {
            return .failed("\(context): contains both [[phase.role]] and [phase.fanout]; use one")
        }
        if hasRoles {
            guard case .tableArray(let roles)? = table["role"] else {
                return .failed("\(context): [[phase.role]] must be an array of tables")
            }
            phase.useFanout = false
            for roleTable in roles {
                switch extractRole(roleTable, context: context, warnings: &warnings) {
                case .failed(let message): return .failed(message)
                case .loaded(let role): phase.roles.append(role)
                }
            }
        } else if hasFanout {
            guard case .table(let fanout)? = table["fanout"] else {
                return .failed("\(context): [phase.fanout] must be a table")
            }
            phase.useFanout = true
            switch extractFanout(fanout, context: context, warnings: &warnings) {
            case .failed(let message): return .failed(message)
            case .loaded(let value): phase.fanout = value
            }
        } else {
            return .failed("\(context): needs at least one [[phase.role]] or a [phase.fanout]")
        }

        if let raw = TomlRead.str(table, "gate") {
            guard let gate = PhaseGate(rawValue: raw) else {
                return .failed("\(context): unknown gate '\(raw)' (authorized, confirm, or auto)")
            }
            phase.gate = gate
        } else {
            // The schema's only stated default is fan-out → confirm; for a
            // fixed-role phase the proposal's first phase runs under the
            // human's initial go-ahead, i.e. authorized. Saving makes the
            // assumed gate explicit in the file.
            phase.gate = phase.useFanout ? .confirm : .authorized
            warnings.append("\(context): no gate field — assumed '\(phase.gate.rawValue)'; saving makes it explicit")
        }
        return .loaded(phase)
    }

    private static func extractFanout(_ table: [String: TomlValue], context: String,
                                      warnings: inout [String]) -> PackageLoad<EditableFanout> {
        guard let from = TomlRead.str(table, "from"), !from.isEmpty else {
            return .failed("\(context): fan-out requires 'from' (a role in an earlier phase)")
        }
        guard let max = TomlRead.int(table, "max"), max > 0 else {
            return .failed("\(context): fan-out requires a positive integer max")
        }
        guard let type = TomlRead.str(table, "type"), !type.isEmpty else {
            return .failed("\(context): fan-out requires a type")
        }
        guard let cwdRoot = TomlRead.str(table, "cwd_root"), !cwdRoot.isEmpty else {
            return .failed("\(context): fan-out requires a cwd_root")
        }
        TomlRead.unknownFields(table, known: ["from", "max", "type", "cwd_root"],
                               context: "\(context) fan-out", into: &warnings)
        return .loaded(EditableFanout(from: from, max: max, type: type, cwdRoot: cwdRoot))
    }
}

// MARK: - Agent-type loader

enum AgentTypeLoader {
    static func load(directory: URL) -> PackageLoad<EditableAgentType> {
        let manifestURL = directory.appendingPathComponent("type.toml")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return .failed("missing type.toml")
        }
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            return .failed("type.toml is not readable UTF-8")
        }
        switch TomlParser.parse(text) {
        case .failure(let error):
            return .failed("type.toml line \(error.line): \(error.message)")
        case .success(let root):
            return extract(root: root, directory: directory)
        }
    }

    private static func extract(root: [String: TomlValue], directory: URL)
        -> PackageLoad<EditableAgentType>
    {
        var warnings: [String] = []
        var type = EditableAgentType(id: directory.lastPathComponent, directoryURL: directory)

        guard case .table(let header)? = root["type"] else {
            return .failed("missing [type] table")
        }
        TomlRead.unknownFields(header, known: ["name", "version", "description"],
                               context: "[type]", into: &warnings)
        guard let name = TomlRead.str(header, "name"), !name.isEmpty else {
            return .failed("[type] requires a nonempty name")
        }
        guard let version = TomlRead.int(header, "version"), version > 0 else {
            return .failed("[type] requires a positive integer version")
        }
        guard let description = TomlRead.str(header, "description"), !description.isEmpty else {
            return .failed("[type] requires a description")
        }
        type.name = name
        type.version = version
        type.description = description

        guard case .table(let provider)? = root["provider"] else {
            return .failed("missing [provider] table")
        }
        TomlRead.unknownFields(provider, known: ["prefer", "model", "requires"],
                               context: "[provider]", into: &warnings)
        guard let prefer = TomlRead.stringList(provider, "prefer"), !prefer.isEmpty else {
            return .failed("[provider] requires a nonempty prefer list")
        }
        type.prefer = prefer
        type.model = TomlRead.str(provider, "model") ?? ""
        type.requires = TomlRead.stringList(provider, "requires") ?? []

        guard case .table(let persona)? = root["persona"] else {
            return .failed("missing [persona] table")
        }
        TomlRead.unknownFields(persona, known: ["prompt", "title"],
                               context: "[persona]", into: &warnings)
        guard let promptFile = TomlRead.str(persona, "prompt"), !promptFile.isEmpty else {
            return .failed("[persona] requires a prompt file path")
        }
        guard let title = TomlRead.str(persona, "title"), !title.isEmpty else {
            return .failed("[persona] requires a title")
        }
        type.personaPromptFile = promptFile
        type.personaTitle = title

        if case .table(let advisory)? = root["advisory"] {
            TomlRead.unknownFields(advisory, known: ["scope", "output", "escalate_as"],
                                   context: "[advisory]", into: &warnings)
            type.advisoryScope = TomlRead.str(advisory, "scope") ?? ""
            type.advisoryOutput = TomlRead.str(advisory, "output") ?? ""
            type.advisoryEscalateAs = TomlRead.str(advisory, "escalate_as") ?? ""
        }

        if case .table(let enforced)? = root["enforced"] {
            // The schema rejects unknown enforced fields outright (they would
            // be unverifiable claims), so they are load errors, not warnings.
            let known: Set<String> = ["read_only", "allow_paths"]
            for key in enforced.keys.sorted() where !known.contains(key) {
                return .failed("[enforced]: unknown field '\(key)' — enforced constraints fail closed")
            }
            if let raw = enforced["read_only"] {
                guard case .bool(let value) = raw, value else {
                    return .failed("[enforced] read_only may only be true; false makes no enforceable claim")
                }
                type.enforcedReadOnly = true
            }
            type.allowPaths = TomlRead.stringList(enforced, "allow_paths") ?? []
        }

        for key in root.keys.sorted()
        where !["type", "provider", "persona", "advisory", "enforced"].contains(key) {
            warnings.append("unknown table '\(key)' — saving rewrites type.toml without it")
        }

        let personaURL = directory.appendingPathComponent(promptFile)
        if let markdown = try? String(contentsOf: personaURL, encoding: .utf8) {
            type.personaMarkdown = markdown
        } else {
            warnings.append("persona file '\(promptFile)' is missing — it will be created on save")
        }
        type.warnings = warnings
        return .loaded(type)
    }
}

// MARK: - Canonical TOML serializers

private enum TomlEmit {
    static func basicString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func stringArray(_ values: [String]) -> String {
        "[" + values.map(basicString).joined(separator: ", ") + "]"
    }

    static func kv(_ key: String, _ value: String) -> String {
        "\(key) = \(basicString(value))\n"
    }
}

enum FormationSerializer {
    static func serialize(_ formation: EditableFormation) -> String {
        var out = "[formation]\n"
        out += TomlEmit.kv("name", formation.name)
        out += "version = \(formation.version)\n"
        out += TomlEmit.kv("description", formation.description)
        out += "\n"

        if formation.phased {
            for phase in formation.phases {
                out += "[[phase]]\n"
                out += TomlEmit.kv("name", phase.name)
                if let after = phase.after { out += TomlEmit.kv("after", after) }
                out += TomlEmit.kv("gate", phase.gate.rawValue)
                out += "\n"
                if phase.useFanout {
                    out += "[phase.fanout]\n"
                    out += TomlEmit.kv("from", phase.fanout.from)
                    out += "max = \(phase.fanout.max)\n"
                    out += TomlEmit.kv("type", phase.fanout.type)
                    out += TomlEmit.kv("cwd_root", phase.fanout.cwdRoot)
                    out += "\n"
                } else {
                    for role in phase.roles {
                        out += "[[phase.role]]\n"
                        out += roleLines(role)
                        out += "\n"
                    }
                }
            }
        } else {
            for role in formation.roles {
                out += "[[role]]\n"
                out += roleLines(role)
                out += "\n"
            }
        }

        out += "[escalate]\n"
        out += "channel_kinds = \(TomlEmit.stringArray(formation.escalate.channelKinds))\n"
        out += "states = \(TomlEmit.stringArray(formation.escalate.states))\n"
        out += TomlEmit.kv("completion", formation.escalate.completion)
        return out
    }

    private static func roleLines(_ role: EditableRole) -> String {
        var out = TomlEmit.kv("name", role.name)
        out += TomlEmit.kv("type", role.type)
        if role.kind == .orchestrator { out += TomlEmit.kv("kind", "orchestrator") }
        if !role.prep.isEmpty { out += TomlEmit.kv("prep", role.prep) }
        if !role.task.isEmpty { out += TomlEmit.kv("task", role.task) }
        return out
    }
}

enum AgentTypeSerializer {
    static func serialize(_ type: EditableAgentType) -> String {
        var out = "[type]\n"
        out += TomlEmit.kv("name", type.name)
        out += "version = \(type.version)\n"
        out += TomlEmit.kv("description", type.description)
        out += "\n[provider]\n"
        out += "prefer = \(TomlEmit.stringArray(type.prefer))\n"
        if !type.model.isEmpty { out += TomlEmit.kv("model", type.model) }
        if !type.requires.isEmpty {
            out += "requires = \(TomlEmit.stringArray(type.requires))\n"
        }
        out += "\n[persona]\n"
        out += TomlEmit.kv("prompt", type.personaPromptFile)
        out += TomlEmit.kv("title", type.personaTitle)

        if !type.advisoryScope.isEmpty || !type.advisoryOutput.isEmpty
            || !type.advisoryEscalateAs.isEmpty {
            out += "\n[advisory]\n"
            if !type.advisoryScope.isEmpty { out += TomlEmit.kv("scope", type.advisoryScope) }
            if !type.advisoryOutput.isEmpty { out += TomlEmit.kv("output", type.advisoryOutput) }
            if !type.advisoryEscalateAs.isEmpty {
                out += TomlEmit.kv("escalate_as", type.advisoryEscalateAs)
            }
        }

        if type.enforcedReadOnly || !type.allowPaths.isEmpty {
            out += "\n[enforced]\n"
            if type.enforcedReadOnly { out += "read_only = true\n" }
            if !type.allowPaths.isEmpty {
                out += "allow_paths = \(TomlEmit.stringArray(type.allowPaths))\n"
            }
        }
        return out
    }
}

// MARK: - Save-time validation (mirrors docs/workflows-schema.md)

enum EditorValidation {

    /// (errors, warnings). Errors block Save; warnings (e.g. a role naming an
    /// agent type that isn't installed) are shown but allowed — resolution is
    /// the orchestrator's job at run time.
    static func formation(_ formation: EditableFormation,
                          installedTypes: [String]) -> (errors: [String], warnings: [String]) {
        var errors: [String] = []
        var warnings: [String] = []

        if !isKebabCase(formation.name) {
            errors.append("Name must be lowercase kebab-case (e.g. review-fanout)")
        }
        if !(1...2).contains(formation.version) {
            errors.append("Schema version must be 1")
        }
        if formation.description.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Description is required")
        }

        var allRoleNames: [String] = []
        func checkRole(_ role: EditableRole, context: String) {
            if role.name.trimmingCharacters(in: .whitespaces).isEmpty {
                errors.append("\(context): a role needs a name")
            }
            allRoleNames.append(role.name)
            if role.type.trimmingCharacters(in: .whitespaces).isEmpty {
                errors.append("\(context) '\(role.name)': choose an agent type")
            } else if !installedTypes.contains(role.type) {
                warnings.append("\(context) '\(role.name)': agent type '\(role.type)' is not installed under agents/")
            }
            if !role.prep.isEmpty && role.prep != "worktree" {
                errors.append("\(context) '\(role.name)': schema v1 only accepts prep = \"worktree\"")
            }
        }

        if formation.phased {
            if formation.phases.isEmpty {
                errors.append("Add at least one phase (or switch to the single-phase roles form)")
            }
            var earlierPhaseNames: [String] = []
            var earlierRoleNames: [String] = []
            for phase in formation.phases {
                let context = "Phase '\(phase.name.isEmpty ? "?" : phase.name)'"
                if phase.name.trimmingCharacters(in: .whitespaces).isEmpty {
                    errors.append("A phase needs a name")
                } else if earlierPhaseNames.contains(phase.name) {
                    errors.append("Duplicate phase name '\(phase.name)'")
                }
                if let after = phase.after, !earlierPhaseNames.contains(after) {
                    errors.append("\(context): 'after' must name an earlier phase ('\(after)' isn't one)")
                }
                if phase.useFanout {
                    if phase.gate == .auto {
                        errors.append("\(context): a fan-out phase must never use gate Auto — plan-authored process creation requires a human gate")
                    }
                    if phase.fanout.from.trimmingCharacters(in: .whitespaces).isEmpty {
                        errors.append("\(context): fan-out needs a 'from' role")
                    } else if !earlierRoleNames.contains(phase.fanout.from) {
                        errors.append("\(context): fan-out 'from' must name a role in an earlier phase ('\(phase.fanout.from)' isn't one)")
                    }
                    if phase.fanout.max < 1 {
                        errors.append("\(context): fan-out max must be at least 1")
                    }
                    if phase.fanout.type.trimmingCharacters(in: .whitespaces).isEmpty {
                        errors.append("\(context): fan-out needs an agent type")
                    } else if !installedTypes.contains(phase.fanout.type) {
                        warnings.append("\(context): agent type '\(phase.fanout.type)' is not installed under agents/")
                    }
                    if let problem = relativePathProblem(phase.fanout.cwdRoot) {
                        errors.append("\(context): cwd_root \(problem)")
                    }
                } else {
                    if phase.roles.isEmpty {
                        errors.append("\(context): add at least one role (or switch to fan-out)")
                    }
                    for role in phase.roles { checkRole(role, context: context) }
                }
                earlierPhaseNames.append(phase.name)
                earlierRoleNames.append(contentsOf: phase.roles.map(\.name))
            }
            let counts = Dictionary(grouping: allRoleNames, by: { $0 })
            for name in counts.keys.sorted() where !name.isEmpty && counts[name]!.count > 1 {
                errors.append("Role name '\(name)' is used more than once")
            }
        } else {
            if formation.roles.isEmpty {
                errors.append("Add at least one role (or switch to phases)")
            }
            for role in formation.roles { checkRole(role, context: "Role") }
            let counts = Dictionary(grouping: allRoleNames, by: { $0 })
            for name in counts.keys.sorted() where !name.isEmpty && counts[name]!.count > 1 {
                errors.append("Role name '\(name)' is used more than once")
            }
        }

        if formation.escalate.channelKinds.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            errors.append("Escalation needs at least one channel kind")
        }
        if formation.escalate.states.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            errors.append("Escalation needs at least one state")
        }
        if formation.escalate.completion.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Escalation needs a completion policy (e.g. all-roles-done)")
        }
        return (errors, warnings)
    }

    static func agentType(_ type: EditableAgentType) -> (errors: [String], warnings: [String]) {
        var errors: [String] = []
        var warnings: [String] = []

        if !isKebabCase(type.name) {
            errors.append("Name must be lowercase kebab-case (e.g. security-reviewer)")
        }
        if type.version < 1 {
            errors.append("Version must be a positive integer")
        }
        if type.description.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Description is required")
        }
        if type.prefer.isEmpty {
            errors.append("Choose at least one preferred provider")
        }
        for provider in type.prefer where !WorkflowEditorModel.knownProviders.contains(provider) {
            errors.append("Unknown provider '\(provider)' (claude, codex, or cursor)")
        }
        let counts = Dictionary(grouping: type.prefer, by: { $0 })
        if counts.values.contains(where: { $0.count > 1 }) {
            errors.append("Provider list has duplicates")
        }
        if type.personaTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Persona title is required")
        }
        if let problem = relativePathProblem(type.personaPromptFile) {
            errors.append("Persona prompt path \(problem)")
        }
        for path in type.allowPaths {
            if let problem = relativePathProblem(path) {
                errors.append("allow_paths entry '\(path)' \(problem)")
            }
        }
        if type.personaMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append("The persona prompt is empty — the agent launches with no persona text")
        }
        return (errors, warnings)
    }

    static func isKebabCase(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("-"), !value.hasSuffix("-"),
              !value.contains("--") else { return false }
        return value.allSatisfy {
            $0.isASCII && (($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "-")
        }
    }

    /// Nil when `path` is a usable package-relative path; otherwise the
    /// problem phrase, worded to complete the sentence "... <problem>".
    static func relativePathProblem(_ path: String) -> String? {
        if path.trimmingCharacters(in: .whitespaces).isEmpty { return "must not be empty" }
        if path.hasPrefix("/") { return "must be relative, not absolute" }
        if path.split(separator: "/").contains("..") { return "must not contain '..' traversal" }
        return nil
    }
}

// MARK: - Editor store

@MainActor
final class WorkflowEditorModel: ObservableObject {

    @Published var formations: [EditableFormation] = []
    @Published var agentTypes: [EditableAgentType] = []
    @Published var broken: [BrokenPackage] = []
    @Published var bundledFormations: [EditableFormation] = []
    @Published var bundledAgentTypes: [EditableAgentType] = []
    @Published var bundledBroken: [BrokenPackage] = []
    @Published var selection: EditorSelection?

    /// Last-saved (or last-loaded) value per package id — dirty tracking is
    /// a plain Equatable diff against these.
    private var formationSnapshots: [String: EditableFormation] = [:]
    private var agentTypeSnapshots: [String: EditableAgentType] = [:]

    nonisolated static let knownProviders = ["claude", "codex", "cursor"]

    nonisolated static var configRoot: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("focalpoint", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".config/focalpoint", isDirectory: true)
    }

    nonisolated static var workflowsDirectory: URL {
        configRoot.appendingPathComponent("workflows", isDirectory: true)
    }

    nonisolated static var agentsDirectory: URL {
        configRoot.appendingPathComponent("agents", isDirectory: true)
    }

    /// Bundled packages ship as app resources and remain separate from user
    /// configuration until an explicit catalog install copies them there.
    nonisolated static var bundledCatalogDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("BundledPackages", isDirectory: true)
    }

    var installedTypeNames: [String] { agentTypes.map(\.name).sorted() }

    // MARK: Dirty tracking

    func isDirty(_ formation: EditableFormation) -> Bool {
        formationSnapshots[formation.id] != formation
    }

    func isDirty(_ type: EditableAgentType) -> Bool {
        agentTypeSnapshots[type.id] != type
    }

    // MARK: Loading

    func reload() {
        let workflowsDir = Self.workflowsDirectory
        let agentsDir = Self.agentsDirectory
        let bundledRoot = Self.bundledCatalogDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.scan(workflows: workflowsDir, agents: agentsDir)
            let bundled = bundledRoot.map {
                Self.scan(workflows: $0.appendingPathComponent("workflows", isDirectory: true),
                          agents: $0.appendingPathComponent("agents", isDirectory: true))
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A reload must not silently discard unsaved edits: packages
                // dirty in memory keep their edited copy; the fresh load only
                // lands for clean packages.
                self.formations = result.formations.map { loaded in
                    if let existing = self.formations.first(where: { $0.id == loaded.id }),
                       self.formationSnapshots[existing.id] != existing {
                        return existing
                    }
                    self.formationSnapshots[loaded.id] = loaded
                    return loaded
                }
                self.agentTypes = result.agentTypes.map { loaded in
                    if let existing = self.agentTypes.first(where: { $0.id == loaded.id }),
                       self.agentTypeSnapshots[existing.id] != existing {
                        return existing
                    }
                    self.agentTypeSnapshots[loaded.id] = loaded
                    return loaded
                }
                self.broken = result.broken
                self.bundledFormations = bundled?.formations ?? []
                self.bundledAgentTypes = bundled?.agentTypes ?? []
                self.bundledBroken = bundled?.broken ?? []
                if let selection = self.selection, !self.selectionExists(selection) {
                    self.selection = nil
                }
            }
        }
    }

    private func selectionExists(_ selection: EditorSelection) -> Bool {
        switch selection {
        case .formation(let id): return formations.contains { $0.id == id }
        case .agentType(let id): return agentTypes.contains { $0.id == id }
        case .bundledFormation(let id): return bundledFormations.contains { $0.id == id }
        case .bundledAgentType(let id): return bundledAgentTypes.contains { $0.id == id }
        case .broken(let kind, let id):
            return broken.contains { $0.id == id && $0.kind == kind }
        }
    }

    /// The UI must call this only after its explicit confirmation dialog. The
    /// core installer rejects every collision and never overwrites a package.
    func installBundledFormation(_ formation: EditableFormation) -> String? {
        guard let sourceRoot = Self.bundledCatalogDirectory else {
            return "Bundled catalog resources are unavailable."
        }
        let planning = BundledCatalogInstallPlan.formation(
            name: formation.id, sourceRoot: sourceRoot, configRoot: Self.configRoot,
            referencedAgentTypes: formation.referencedAgentTypes
        )
        guard case .success(let plan) = planning else {
            if case .failure(let error) = planning { return error }
            return "Could not plan bundled formation installation."
        }
        switch plan.install() {
        case .success:
            log("workflow editor installed bundled formation \(boundedLogField(formation.name))")
            reload()
            return nil
        case .failure(let error): return error
        }
    }

    func installBundledAgentType(_ type: EditableAgentType) -> String? {
        guard let sourceRoot = Self.bundledCatalogDirectory else {
            return "Bundled catalog resources are unavailable."
        }
        let planning = BundledCatalogInstallPlan.agentType(
            name: type.id, sourceRoot: sourceRoot, configRoot: Self.configRoot
        )
        guard case .success(let plan) = planning else {
            if case .failure(let error) = planning { return error }
            return "Could not plan bundled agent installation."
        }
        switch plan.install() {
        case .success:
            log("workflow editor installed bundled agent type \(boundedLogField(type.name))")
            reload()
            return nil
        case .failure(let error): return error
        }
    }

    nonisolated private static func scan(workflows: URL, agents: URL)
        -> (formations: [EditableFormation], agentTypes: [EditableAgentType], broken: [BrokenPackage])
    {
        let fm = FileManager.default
        var formations: [EditableFormation] = []
        var agentTypes: [EditableAgentType] = []
        var broken: [BrokenPackage] = []

        func subdirectories(of directory: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: directory,
                                         includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles]))?
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        }

        for directory in subdirectories(of: workflows) {
            switch FormationLoader.load(directory: directory) {
            case .loaded(let formation): formations.append(formation)
            case .failed(let message):
                broken.append(BrokenPackage(id: directory.lastPathComponent, kind: .formation,
                                            directoryURL: directory, message: message))
            }
        }
        for directory in subdirectories(of: agents) {
            switch AgentTypeLoader.load(directory: directory) {
            case .loaded(let type): agentTypes.append(type)
            case .failed(let message):
                broken.append(BrokenPackage(id: directory.lastPathComponent, kind: .agentType,
                                            directoryURL: directory, message: message))
            }
        }
        return (formations, agentTypes, broken)
    }

    // MARK: Saving

    /// Returns nil on success, else the reason. Validation errors are
    /// normally caught by the disabled Save button; this is the backstop.
    @discardableResult
    func saveFormation(_ formation: EditableFormation) -> String? {
        let (errors, _) = EditorValidation.formation(formation, installedTypes: installedTypeNames)
        guard errors.isEmpty else { return errors.first }
        let manifestURL = formation.directoryURL.appendingPathComponent("formation.toml")
        do {
            try FileManager.default.createDirectory(at: formation.directoryURL,
                                                    withIntermediateDirectories: true)
            try FormationSerializer.serialize(formation)
                .write(to: manifestURL, atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        formationSnapshots[formation.id] = formation
        log("workflow editor saved formation \(boundedLogField(formation.name))")
        return nil
    }

    @discardableResult
    func saveAgentType(_ type: EditableAgentType) -> String? {
        let (errors, _) = EditorValidation.agentType(type)
        guard errors.isEmpty else { return errors.first }
        do {
            try FileManager.default.createDirectory(at: type.directoryURL,
                                                    withIntermediateDirectories: true)
            try AgentTypeSerializer.serialize(type)
                .write(to: type.directoryURL.appendingPathComponent("type.toml"),
                       atomically: true, encoding: .utf8)
            try type.personaMarkdown
                .write(to: type.directoryURL.appendingPathComponent(type.personaPromptFile),
                       atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        agentTypeSnapshots[type.id] = type
        log("workflow editor saved agent type \(boundedLogField(type.name))")
        return nil
    }

    func revertFormation(_ formation: EditableFormation) {
        guard let snapshot = formationSnapshots[formation.id],
              let index = formations.firstIndex(where: { $0.id == formation.id }) else { return }
        formations[index] = snapshot
    }

    func revertAgentType(_ type: EditableAgentType) {
        guard let snapshot = agentTypeSnapshots[type.id],
              let index = agentTypes.firstIndex(where: { $0.id == type.id }) else { return }
        agentTypes[index] = snapshot
    }

    // MARK: Create / delete

    func createFormation() {
        let directory = uniqueDirectory(under: Self.workflowsDirectory, base: "new-formation")
        var formation = EditableFormation(id: directory.lastPathComponent, directoryURL: directory)
        formation.name = directory.lastPathComponent
        formation.description = "Describe what this formation delivers"
        formation.phased = true
        formation.phases = [
            EditablePhase(id: UUID(), name: "plan", after: nil, gate: .authorized,
                          useFanout: false,
                          roles: [EditableRole(id: UUID(), name: "planner",
                                               type: installedTypeNames.first ?? "planner")],
                          fanout: EditableFanout()),
        ]
        if let error = saveFormation(formation) {
            log("workflow editor create formation failed: \(boundedLogField(error))")
            return
        }
        reload()
        selection = .formation(formation.id)
    }

    func createAgentType() {
        let directory = uniqueDirectory(under: Self.agentsDirectory, base: "new-agent")
        var type = EditableAgentType(id: directory.lastPathComponent, directoryURL: directory)
        type.name = directory.lastPathComponent
        type.description = "Describe this agent's role in one line"
        type.personaTitle = "New agent"
        type.personaMarkdown = """
        # New agent

        Describe the persona here: what it is for, how it should behave, what
        it must never do, and the shape of its output.
        """
        if let error = saveAgentType(type) {
            log("workflow editor create agent type failed: \(boundedLogField(error))")
            return
        }
        reload()
        selection = .agentType(type.id)
    }

    /// Moves the package directory to the Trash (recoverable, unlike rm).
    func delete(_ target: EditorSelection) {
        guard let url = directoryURL(for: target) else { return }
        NSWorkspace.shared.recycle([url]) { _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    log("workflow editor trash failed: \(boundedLogField(error.localizedDescription))")
                }
                if self.selection == target { self.selection = nil }
                self.reload()
            }
        }
    }

    func directoryURL(for target: EditorSelection) -> URL? {
        switch target {
        case .formation(let id):
            return formations.first { $0.id == id }?.directoryURL
        case .agentType(let id):
            return agentTypes.first { $0.id == id }?.directoryURL
        case .bundledFormation(let id):
            return bundledFormations.first { $0.id == id }?.directoryURL
        case .bundledAgentType(let id):
            return bundledAgentTypes.first { $0.id == id }?.directoryURL
        case .broken(let kind, let id):
            return broken.first { $0.id == id && $0.kind == kind }?.directoryURL
        }
    }

    func reveal(_ target: EditorSelection) {
        if let url = directoryURL(for: target) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func uniqueDirectory(under parent: URL, base: String) -> URL {
        let fm = FileManager.default
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }
}

// MARK: - Editor window

/// Owns the one Workflow Editor window. Follows the Settings window pattern
/// (lazily created NSWindow hosting SwiftUI, non-opaque with a transparent
/// titlebar so the pane materials render as real vibrancy), but lives here
/// rather than on AppDelegate so the feature adds no edits outside its own
/// files.
@MainActor
final class WorkflowEditorWindow {
    static let shared = WorkflowEditorWindow()

    private var windowController: NSWindowController?
    private let store = WorkflowEditorModel()

    func show() {
        if windowController == nil {
            let viewController = NSHostingController(rootView: WorkflowEditorView(store: store))
            let window = NSWindow(contentViewController: viewController)
            window.title = "Workflow Editor"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 780, height: 540))
            window.setFrameAutosaveName("FocalPointWorkflowEditor")
            if !window.setFrameUsingName("FocalPointWorkflowEditor") {
                window.center()
            }
            windowController = NSWindowController(window: window)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        store.reload()
    }
}
