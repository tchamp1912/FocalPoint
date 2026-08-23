#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 (3.11 or newer) is required" >&2
    exit 2
fi

exec python3 - "$script_dir" "$@" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path, PurePosixPath, PureWindowsPath

try:
    import tomllib
except ModuleNotFoundError:
    print("error: python3 3.11 or newer is required (tomllib is unavailable)", file=sys.stderr)
    raise SystemExit(2)


ALLOWED_PROVIDERS = {"claude", "codex", "cursor"}
COMPLEXITIES = {"focused", "substantial", "complex"}
FORBIDDEN_SELECTIONS = {"auto", "default", "general", "provider-default"}

# Fail-closed capability inventory. A provider must be present here and list
# every requested field before an agent type with [enforced] can validate.
# Verified 2026-08-20 against the provider docs linked in
# docs/workflows-schema.md.
ENFORCEMENT_FIELDS = {
    "claude": {"read_only", "allow_paths"},
    "codex": {"read_only", "allow_paths"},
    "cursor": {"read_only", "allow_paths"},
}

NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
GATES = {"authorized", "confirm", "auto"}
ROLE_KINDS = {"worker", "orchestrator"}


class Validation:
    def __init__(self, manifest: Path) -> None:
        self.manifest = manifest
        self.errors: list[str] = []

    def error(self, message: str) -> None:
        self.errors.append(message)

    def table(self, parent: dict, key: str, label: str, required: bool = True) -> dict | None:
        value = parent.get(key)
        if value is None:
            if required:
                self.error(f"missing required table {label}")
            return None
        if not isinstance(value, dict):
            self.error(f"{label} must be a table")
            return None
        return value

    def nonempty_string(self, table: dict, key: str, label: str, required: bool = True) -> str | None:
        value = table.get(key)
        if value is None:
            if required:
                self.error(f"missing required field {label}")
            return None
        if not isinstance(value, str) or not value.strip():
            self.error(f"{label} must be a nonempty string")
            return None
        return value

    def positive_int(self, table: dict, key: str, label: str) -> int | None:
        value = table.get(key)
        if value is None:
            self.error(f"missing required field {label}")
            return None
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            self.error(f"{label} must be a positive integer")
            return None
        return value

    def string_list(self, table: dict, key: str, label: str, required: bool = True) -> list[str] | None:
        value = table.get(key)
        if value is None:
            if required:
                self.error(f"missing required field {label}")
            return None
        if not isinstance(value, list) or not value:
            self.error(f"{label} must be a nonempty array of strings")
            return None
        if any(not isinstance(item, str) or not item.strip() for item in value):
            self.error(f"{label} must contain only nonempty strings")
            return None
        if len(value) != len(set(value)):
            self.error(f"{label} must not contain duplicates")
            return None
        return value

    def only_keys(self, table: dict, allowed: set[str], label: str) -> None:
        for key in sorted(set(table) - allowed):
            self.error(f"unknown field {label}.{key}")


def is_relative_contained_path(value: str) -> bool:
    if not value or "\x00" in value:
        return False
    normalized = value.replace("\\", "/")
    posix = PurePosixPath(normalized)
    windows = PureWindowsPath(value)
    if posix.is_absolute() or windows.is_absolute():
        return False
    return ".." not in posix.parts


def validate_name(v: Validation, value: str | None, label: str) -> None:
    if value is not None and not NAME_RE.fullmatch(value):
        v.error(f"{label} must use lowercase kebab-case")


def validate_role(v: Validation, role: object, label: str) -> str | None:
    if not isinstance(role, dict):
        v.error(f"{label} must be a table")
        return None
    v.only_keys(role, {"name", "kind", "type", "prep", "task"}, label)
    name = v.nonempty_string(role, "name", f"{label}.name")
    type_name = v.nonempty_string(role, "type", f"{label}.type")
    validate_name(v, name, f"{label}.name")
    validate_name(v, type_name, f"{label}.type")

    kind = role.get("kind")
    if kind is not None and kind not in ROLE_KINDS:
        v.error(f"{label}.kind must be one of: {', '.join(sorted(ROLE_KINDS))}")
    prep = role.get("prep")
    if prep is not None and prep != "worktree":
        v.error(f"{label}.prep must be 'worktree' when present")
    if "task" in role:
        v.nonempty_string(role, "task", f"{label}.task")
    return name


def validate_escalate(v: Validation, data: dict) -> None:
    escalate = v.table(data, "escalate", "[escalate]")
    if escalate is None:
        return
    v.only_keys(escalate, {"channel_kinds", "states", "completion"}, "escalate")
    v.string_list(escalate, "channel_kinds", "escalate.channel_kinds")
    v.string_list(escalate, "states", "escalate.states")
    v.nonempty_string(escalate, "completion", "escalate.completion")


def validate_agent(manifest: Path, data: dict) -> list[str]:
    v = Validation(manifest)
    v.only_keys(data, {"type", "provider", "persona", "advisory", "enforced"}, "root")

    type_table = v.table(data, "type", "[type]")
    if type_table is not None:
        v.only_keys(type_table, {"name", "version", "description"}, "type")
        name = v.nonempty_string(type_table, "name", "type.name")
        validate_name(v, name, "type.name")
        v.positive_int(type_table, "version", "type.version")
        v.nonempty_string(type_table, "description", "type.description")

    providers: list[str] = []
    provider = v.table(data, "provider", "[provider]")
    if provider is not None:
        v.only_keys(provider, {"prefer", "model", "requires"}, "provider")
        providers = v.string_list(provider, "prefer", "provider.prefer") or []
        for item in providers:
            if item not in ALLOWED_PROVIDERS:
                v.error(
                    "provider.prefer contains unsupported provider "
                    f"{item!r}; expected one of: {', '.join(sorted(ALLOWED_PROVIDERS))}"
                )
        if "model" in provider:
            v.nonempty_string(provider, "model", "provider.model")
        if "requires" in provider:
            v.string_list(provider, "requires", "provider.requires")

    persona = v.table(data, "persona", "[persona]")
    if persona is not None:
        v.only_keys(persona, {"prompt", "title"}, "persona")
        prompt = v.nonempty_string(persona, "prompt", "persona.prompt")
        v.nonempty_string(persona, "title", "persona.title")
        if prompt is not None:
            if prompt != "persona.md":
                v.error("persona.prompt must be 'persona.md' in schema version 1")
            else:
                prompt_path = manifest.parent / prompt
                if prompt_path.is_symlink():
                    v.error("persona.md must not be a symbolic link")
                elif not prompt_path.is_file():
                    v.error("persona.prompt does not name an existing persona.md file")

    advisory = data.get("advisory")
    if advisory is not None:
        if not isinstance(advisory, dict):
            v.error("[advisory] must be a table")
        else:
            v.only_keys(advisory, {"scope", "output", "escalate_as"}, "advisory")
            for key in advisory:
                v.nonempty_string(advisory, key, f"advisory.{key}")

    enforced = data.get("enforced")
    if enforced is not None:
        if not isinstance(enforced, dict):
            v.error("[enforced] must be a table")
        else:
            declared = set(enforced)
            known = {"read_only", "allow_paths"}
            v.only_keys(enforced, known, "enforced")
            if not declared:
                v.error("[enforced] must declare at least one constraint")

            if "read_only" in enforced and enforced["read_only"] is not True:
                v.error("enforced.read_only must be true")
            if "allow_paths" in enforced:
                allow_paths = v.string_list(enforced, "allow_paths", "enforced.allow_paths") or []
                for path in allow_paths:
                    if not is_relative_contained_path(path):
                        v.error(
                            f"enforced.allow_paths entry {path!r} must be relative and cannot contain '..'"
                        )

            # Unknown fields are already errors. The provider test intentionally
            # uses every declared key so an incomplete surface can never degrade.
            for provider_name in providers:
                supported = ENFORCEMENT_FIELDS.get(provider_name)
                if supported is None:
                    v.error(
                        f"provider {provider_name!r} has no verified project-local enforcement surface"
                    )
                    continue
                missing = declared - supported
                if missing:
                    v.error(
                        f"provider {provider_name!r} cannot enforce: {', '.join(sorted(missing))}"
                    )

    return v.errors


def validate_catalog(manifest: Path, data: dict) -> list[str]:
    v = Validation(manifest)
    v.only_keys(data, {"catalog", "resolution", "selection"}, "root")
    catalog = v.table(data, "catalog", "[catalog]")
    if catalog is not None:
        v.only_keys(catalog, {"version"}, "catalog")
        if catalog.get("version") != 1:
            v.error("catalog.version must be 1")

    resolutions = data.get("resolution")
    if not isinstance(resolutions, list) or not resolutions:
        v.error("[[resolution]] must be a nonempty array of tables")
    else:
        seen_resolution: set[tuple[str, str]] = set()
        for index, resolution in enumerate(resolutions):
            label = f"resolution[{index}]"
            if not isinstance(resolution, dict):
                v.error(f"{label} must be a table")
                continue
            v.only_keys(resolution, {"provider", "complexity", "agent_type"}, label)
            provider = v.nonempty_string(resolution, "provider", f"{label}.provider")
            complexity = v.nonempty_string(resolution, "complexity", f"{label}.complexity")
            agent_type = v.nonempty_string(resolution, "agent_type", f"{label}.agent_type")
            if provider is not None and provider not in ALLOWED_PROVIDERS:
                v.error(f"{label}.provider must be one of: {', '.join(sorted(ALLOWED_PROVIDERS))}")
            if complexity is not None and complexity not in COMPLEXITIES:
                v.error(f"{label}.complexity must be one of: {', '.join(sorted(COMPLEXITIES))}")
            if agent_type is not None:
                validate_name(v, agent_type, f"{label}.agent_type")
            if complexity is not None and agent_type is not None:
                key = (complexity, agent_type)
                if key in seen_resolution:
                    v.error(f"duplicate resolution for complexity={complexity!r}, agent_type={agent_type!r}")
                seen_resolution.add(key)

    selections = data.get("selection")
    if not isinstance(selections, list) or not selections:
        v.error("[[selection]] must be a nonempty array of tables")
        return v.errors
    seen: set[tuple[str, str, str]] = set()
    for index, selection in enumerate(selections):
        label = f"selection[{index}]"
        if not isinstance(selection, dict):
            v.error(f"{label} must be a table")
            continue
        v.only_keys(selection, {"provider", "complexity", "agent_type", "model"}, label)
        provider = v.nonempty_string(selection, "provider", f"{label}.provider")
        complexity = v.nonempty_string(selection, "complexity", f"{label}.complexity")
        agent_type = v.nonempty_string(selection, "agent_type", f"{label}.agent_type")
        model = v.nonempty_string(selection, "model", f"{label}.model")
        if provider is not None and provider not in ALLOWED_PROVIDERS:
            v.error(f"{label}.provider must be one of: {', '.join(sorted(ALLOWED_PROVIDERS))}")
        if complexity is not None and complexity not in COMPLEXITIES:
            v.error(f"{label}.complexity must be one of: {', '.join(sorted(COMPLEXITIES))}")
        if agent_type is not None:
            validate_name(v, agent_type, f"{label}.agent_type")
            if agent_type.lower() in FORBIDDEN_SELECTIONS:
                v.error(f"{label}.agent_type must be concrete")
        if model is not None:
            if model.lower() in FORBIDDEN_SELECTIONS:
                v.error(f"{label}.model must be concrete")
            elif not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/@:-]{0,127}", model):
                v.error(f"{label}.model has invalid characters")
        if provider is not None and complexity is not None and agent_type is not None:
            key = (provider, complexity, agent_type)
            if key in seen:
                v.error(f"duplicate selection for provider={provider!r}, complexity={complexity!r}, agent_type={agent_type!r}")
            seen.add(key)
    return v.errors


def validate_formation(manifest: Path, data: dict) -> list[str]:
    v = Validation(manifest)
    v.only_keys(data, {"formation", "role", "phase", "escalate"}, "root")

    formation = v.table(data, "formation", "[formation]")
    if formation is not None:
        v.only_keys(formation, {"name", "version", "description"}, "formation")
        name = v.nonempty_string(formation, "name", "formation.name")
        validate_name(v, name, "formation.name")
        v.positive_int(formation, "version", "formation.version")
        v.nonempty_string(formation, "description", "formation.description")

    roles = data.get("role")
    phases = data.get("phase")
    if roles is None and phases is None:
        v.error("formation must contain [[role]] or [[phase]] entries")
    if roles is not None and phases is not None:
        v.error("formation cannot mix top-level [[role]] and [[phase]] entries")

    if roles is not None:
        if not isinstance(roles, list) or not roles:
            v.error("[[role]] must be a nonempty array of tables")
        else:
            names: list[str] = []
            for index, role in enumerate(roles):
                name = validate_role(v, role, f"role[{index}]")
                if name is not None:
                    names.append(name)
            if len(names) != len(set(names)):
                v.error("top-level role names must be unique")

    if phases is not None:
        if not isinstance(phases, list) or not phases:
            v.error("[[phase]] must be a nonempty array of tables")
        else:
            phase_names: list[str] = []
            earlier_roles: set[str] = set()
            for index, phase in enumerate(phases):
                label = f"phase[{index}]"
                if not isinstance(phase, dict):
                    v.error(f"{label} must be a table")
                    continue
                v.only_keys(phase, {"name", "after", "gate", "role", "fanout"}, label)
                phase_name = v.nonempty_string(phase, "name", f"{label}.name")
                validate_name(v, phase_name, f"{label}.name")
                if phase_name is not None:
                    if phase_name in phase_names:
                        v.error(f"duplicate phase name {phase_name!r}")
                    phase_names.append(phase_name)

                after = phase.get("after")
                if index == 0 and after is not None:
                    v.error(f"{label}.after is invalid on the first phase")
                elif index > 0:
                    if not isinstance(after, str) or not after.strip():
                        v.error(f"missing required field {label}.after")
                    elif after not in phase_names[:-1]:
                        v.error(f"{label}.after must name an earlier phase")

                phase_roles = phase.get("role")
                fanout = phase.get("fanout")
                if phase_roles is None and fanout is None:
                    v.error(f"{label} must contain [[phase.role]] or [phase.fanout]")
                if phase_roles is not None and fanout is not None:
                    v.error(f"{label} cannot mix [[phase.role]] and [phase.fanout]")

                gate = phase.get("gate")
                if gate is None:
                    if fanout is None:
                        v.error(f"missing required field {label}.gate")
                    else:
                        gate = "confirm"
                elif gate not in GATES:
                    v.error(f"{label}.gate must be one of: {', '.join(sorted(GATES))}")

                if phase_roles is not None:
                    if not isinstance(phase_roles, list) or not phase_roles:
                        v.error(f"{label}.role must be a nonempty array of tables")
                    else:
                        local_names: list[str] = []
                        for role_index, role in enumerate(phase_roles):
                            role_name = validate_role(v, role, f"{label}.role[{role_index}]")
                            if role_name is not None:
                                local_names.append(role_name)
                        if len(local_names) != len(set(local_names)):
                            v.error(f"{label} role names must be unique")
                        earlier_roles.update(local_names)

                if fanout is not None:
                    if not isinstance(fanout, dict):
                        v.error(f"{label}.fanout must be a table")
                    else:
                        v.only_keys(fanout, {"from", "max", "type", "cwd_root"}, f"{label}.fanout")
                        source = v.nonempty_string(fanout, "from", f"{label}.fanout.from")
                        if source is not None and source not in earlier_roles:
                            v.error(f"{label}.fanout.from must name a role in an earlier phase")
                        v.positive_int(fanout, "max", f"{label}.fanout.max")
                        fanout_type = v.nonempty_string(fanout, "type", f"{label}.fanout.type")
                        validate_name(v, fanout_type, f"{label}.fanout.type")
                        cwd_root = v.nonempty_string(fanout, "cwd_root", f"{label}.fanout.cwd_root")
                        if cwd_root is not None and not is_relative_contained_path(cwd_root):
                            v.error(f"{label}.fanout.cwd_root must be relative and cannot contain '..'")
                    if gate == "auto":
                        v.error(f"{label}.gate cannot be 'auto' for fan-out; confirmation is required")

    validate_escalate(v, data)
    return v.errors


def discover(target: Path) -> list[Path]:
    if target.is_file():
        if target.name not in {"type.toml", "formation.toml", "model-catalog.toml"}:
            raise ValueError("manifest file must be named type.toml, formation.toml, or model-catalog.toml")
        return [target]
    if not target.is_dir():
        raise ValueError("path does not exist or is not a directory")

    # A directory may carry one repository-level model catalog plus many
    # package directories. Only type/formation manifests make *this*
    # directory a package; catalog discovery remains recursive.
    direct = [target / "type.toml", target / "formation.toml"]
    present = [path for path in direct if path.is_file()]
    if len(present) > 1:
        raise ValueError("package cannot contain multiple package manifests")
    if present:
        return present

    return sorted([*target.rglob("type.toml"), *target.rglob("formation.toml"), *target.rglob("model-catalog.toml")])


def main() -> int:
    script_dir = Path(sys.argv[1]).resolve()
    raw_targets = sys.argv[2:] or [str(script_dir)]
    manifests: list[Path] = []
    discovery_errors: list[str] = []

    for raw_target in raw_targets:
        target = Path(raw_target).resolve()
        try:
            found = discover(target)
        except ValueError as exc:
            discovery_errors.append(f"{raw_target}: {exc}")
            continue
        if not found:
            discovery_errors.append(f"{raw_target}: no package manifest found")
        manifests.extend(found)

    unique_manifests = list(dict.fromkeys(manifests))
    failures = 0
    for message in discovery_errors:
        print(f"error: {message}", file=sys.stderr)
        failures += 1

    for manifest in unique_manifests:
        try:
            with manifest.open("rb") as handle:
                data = tomllib.load(handle)
        except (OSError, tomllib.TOMLDecodeError) as exc:
            print(f"error: {manifest}: cannot parse TOML: {exc}", file=sys.stderr)
            failures += 1
            continue

        if manifest.name == "type.toml":
            errors = validate_agent(manifest, data)
        elif manifest.name == "formation.toml":
            errors = validate_formation(manifest, data)
        else:
            errors = validate_catalog(manifest, data)

        if errors:
            failures += 1
            for error in errors:
                print(f"error: {manifest}: {error}", file=sys.stderr)
        else:
            print(f"ok: {manifest}")

    if not unique_manifests and not discovery_errors:
        print("error: no package manifest found", file=sys.stderr)
        return 2
    return 1 if failures else 0


raise SystemExit(main())
PY
