//! Config loading and the action model (PROTOCOL.md §5).
//!
//! `~/.config/focalpoint/config.toml`. A missing file means every action defaults
//! to `none` (i.e. events are still reported over the socket, but the daemon
//! synthesizes nothing).

use crate::protocol::{Pattern, State};
use crate::styles::{default_style, Style, StyleTable};
use serde::Deserialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// A single action bound to a device event.
///
/// Tagged by `type` per PROTOCOL.md §5: `keystroke`, `paste`, `shell`, `none`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Default)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Action {
    /// Synthesize a keystroke (e.g. `keys = "enter"`).
    Keystroke { keys: String },
    /// Type/paste literal text.
    Paste { text: String },
    /// Run a shell command via `sh -c`.
    Shell { run: String },
    /// Do nothing.
    #[default]
    None,
}

/// Dial config has a bespoke shape (`mode` + `cw`/`ccw` commands).
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct DialConfig {
    /// Currently only `"shell"` is meaningful; absent means disabled.
    #[serde(default)]
    pub mode: Option<String>,
    /// Command to run on clockwise ticks (delta > 0).
    #[serde(default)]
    pub cw: Option<String>,
    /// Command to run on counter-clockwise ticks (delta < 0).
    #[serde(default)]
    pub ccw: Option<String>,
}

/// `[session]` config block (PROTOCOL.md §3 Focus & §5).
#[derive(Debug, Clone, Default, Deserialize)]
pub struct SessionConfig {
    /// Action run when a numbered key with a live session is pressed. The
    /// session is exposed via `FOCALPOINT_SESSION_*` env vars.
    #[serde(default)]
    pub focus: Option<Action>,
    /// End sessions with no updates for this long. Absent => 60; `0` => never.
    #[serde(default)]
    pub ttl_minutes: Option<u64>,
    /// How long a session reaped by a sweep (not an explicit end-session)
    /// stays recoverable — see `session::Registry::find_recovery_candidate`.
    /// Absent => 30; `0` => never (a session "left through a reboot" stays
    /// recoverable indefinitely — meaningful once persisted, see Part 4).
    #[serde(default)]
    pub tombstone_ttl_minutes: Option<u64>,
}

/// `[channel]` delivery controls. Channel storage itself is always available;
/// this only controls the optional managed tmux wake tier.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct ChannelConfig {
    /// Default-on for managed sessions. A disabled wake never affects pull
    /// delivery or human-visible channel notifications.
    #[serde(default)]
    pub wake_managed: Option<bool>,
}

impl ChannelConfig {
    pub fn wake_managed(&self) -> bool { self.wake_managed.unwrap_or(true) }
}

impl SessionConfig {
    /// Effective TTL: `None` means "never expire".
    pub fn ttl(&self) -> Option<std::time::Duration> {
        match self.ttl_minutes.unwrap_or(60) {
            0 => None,
            m => Some(std::time::Duration::from_secs(m * 60)),
        }
    }

    /// Effective tombstone TTL: `None` means "never expire".
    pub fn tombstone_ttl(&self) -> Option<std::time::Duration> {
        match self.tombstone_ttl_minutes.unwrap_or(30) {
            0 => None,
            m => Some(std::time::Duration::from_secs(m * 60)),
        }
    }
}

/// A `[styles.<state>]` override entry (PROTOCOL.md §5).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct StyleConfig {
    pub rgb: [u8; 3],
    pub pattern: String,
    #[serde(default)]
    pub period_ms: Option<u16>,
}

/// Top-level config document.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct Config {
    /// Keyed by control name (`accept`, `reject`, `new-task`, `key1`..`key12`,
    /// `push-to-talk`, `dial-press`).
    #[serde(default)]
    pub actions: HashMap<String, Action>,
    /// Keyed by gesture name (`north`, `east`, `south`, `west`, `press`).
    #[serde(default)]
    pub joystick: HashMap<String, Action>,
    #[serde(default)]
    pub dial: DialConfig,
    #[serde(default)]
    pub session: SessionConfig,
    #[serde(default)]
    pub channel: ChannelConfig,
    /// Keyed by state name (`idle`..`error`). Overrides the default style.
    #[serde(default)]
    pub styles: HashMap<String, StyleConfig>,
}

impl Config {
    /// Resolve the config path: `$XDG_CONFIG_HOME/focalpoint/config.toml`, else
    /// `~/.config/focalpoint/config.toml` (PROTOCOL.md §5).
    pub fn path() -> Option<PathBuf> {
        if let Some(dir) = std::env::var_os("XDG_CONFIG_HOME") {
            if !dir.is_empty() {
                return Some(PathBuf::from(dir).join("focalpoint").join("config.toml"));
            }
        }
        dirs::home_dir().map(|h| h.join(".config").join("focalpoint").join("config.toml"))
    }

    /// Load from the default path. A missing file yields the default (all
    /// actions `none`). A malformed file returns an error.
    pub fn load() -> Result<Config, String> {
        let Some(path) = Config::path() else {
            return Ok(Config::default());
        };
        match std::fs::read_to_string(&path) {
            Ok(text) => Config::from_toml(&text)
                .map_err(|e| format!("failed to parse {}: {e}", path.display())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Config::default()),
            Err(e) => Err(format!("failed to read {}: {e}", path.display())),
        }
    }

    pub fn from_toml(text: &str) -> Result<Config, toml::de::Error> {
        toml::from_str(text)
    }

    /// Action bound to a control name, defaulting to `none`.
    pub fn action_for(&self, control: &str) -> Action {
        self.actions.get(control).cloned().unwrap_or(Action::None)
    }

    /// Action bound to a joystick gesture, defaulting to `none`.
    pub fn joystick_for(&self, gesture: &str) -> Action {
        self.joystick.get(gesture).cloned().unwrap_or(Action::None)
    }

    /// Build the runtime style table: defaults (PROTOCOL.md §1) overridden by
    /// any `[styles.<state>]` entries. Entries with an unknown state or pattern
    /// are ignored (with a warning); `period_ms` defaults to the state default.
    pub fn style_table(&self) -> StyleTable {
        let mut table = StyleTable::default();
        for (name, sc) in &self.styles {
            let Some(state) = State::from_name(name) else {
                eprintln!("[config] ignoring [styles.{name}]: unknown state");
                continue;
            };
            let Some(pattern) = Pattern::from_name(&sc.pattern) else {
                eprintln!(
                    "[config] ignoring [styles.{name}]: unknown pattern {:?}",
                    sc.pattern
                );
                continue;
            };
            let period = sc
                .period_ms
                .unwrap_or_else(|| default_style(state).period_ms);
            table.set(state, Style::new(sc.rgb, pattern, period));
        }
        table
    }

    /// Persist a single state's style to the config file at `path`, rewriting
    /// only its `[styles.<state>]` table and preserving the rest of the file
    /// (comments/formatting) verbatim. Creates the file if missing.
    pub fn write_style(path: &Path, state: State, style: Style) -> Result<(), String> {
        let existing = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
            Err(e) => return Err(format!("failed to read {}: {e}", path.display())),
        };
        let updated = edit_style_toml(&existing, state, style)?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("failed to create {}: {e}", parent.display()))?;
        }
        std::fs::write(path, updated)
            .map_err(|e| format!("failed to write {}: {e}", path.display()))
    }
}

/// Pure, format-preserving TOML edit: set `[styles.<state>]` in `text`,
/// leaving everything else byte-identical. Exposed for testing.
pub fn edit_style_toml(text: &str, state: State, style: Style) -> Result<String, String> {
    use toml_edit::{value, Array, DocumentMut, Item, Table};

    let mut doc = text
        .parse::<DocumentMut>()
        .map_err(|e| format!("existing config is not valid TOML: {e}"))?;

    // Ensure a `[styles]` table exists; make it implicit so we emit only the
    // `[styles.<state>]` sub-header, not a bare `[styles]`.
    if !doc.contains_key("styles") || !doc["styles"].is_table() {
        let mut t = Table::new();
        t.set_implicit(true);
        doc["styles"] = Item::Table(t);
    }
    let styles = doc["styles"]
        .as_table_mut()
        .expect("styles is a table by construction");

    let entry = styles
        .entry(state.name())
        .or_insert(Item::Table(Table::new()));
    let tbl = entry
        .as_table_mut()
        .ok_or_else(|| format!("[styles.{}] exists but is not a table", state.name()))?;

    let mut rgb = Array::new();
    for c in style.rgb {
        rgb.push(c as i64);
    }
    tbl["rgb"] = value(rgb);
    tbl["pattern"] = value(style.pattern.name());
    tbl["period_ms"] = value(style.period_ms as i64);

    Ok(doc.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXAMPLE: &str = r#"
[actions]
accept  = { type = "keystroke", keys = "enter" }
reject  = { type = "keystroke", keys = "escape" }
new-task = { type = "shell", run = "open -a Terminal" }

[joystick]
north = { type = "paste", text = "Review this PR and summarize the risks." }

[dial]
mode = "shell"
cw   = "echo effort-up"
ccw  = "echo effort-down"
"#;

    #[test]
    fn parses_protocol_example() {
        let cfg = Config::from_toml(EXAMPLE).expect("parse");
        assert_eq!(
            cfg.action_for("accept"),
            Action::Keystroke {
                keys: "enter".into()
            }
        );
        assert_eq!(
            cfg.action_for("new-task"),
            Action::Shell {
                run: "open -a Terminal".into()
            }
        );
        assert_eq!(
            cfg.joystick_for("north"),
            Action::Paste {
                text: "Review this PR and summarize the risks.".into()
            }
        );
        assert_eq!(cfg.dial.mode.as_deref(), Some("shell"));
        assert_eq!(cfg.dial.cw.as_deref(), Some("echo effort-up"));
        assert_eq!(cfg.dial.ccw.as_deref(), Some("echo effort-down"));
    }

    #[test]
    fn unconfigured_actions_default_to_none() {
        let cfg = Config::default();
        assert_eq!(cfg.action_for("accept"), Action::None);
        assert_eq!(cfg.joystick_for("north"), Action::None);
        assert_eq!(cfg.dial.mode, None);
    }

    #[test]
    fn empty_document_is_valid() {
        let cfg = Config::from_toml("").expect("parse empty");
        assert!(cfg.actions.is_empty());
        assert!(cfg.joystick.is_empty());
    }

    #[test]
    fn parses_session_block() {
        let cfg = Config::from_toml(
            r#"
[session]
focus = { type = "shell", run = "focus.sh" }
ttl_minutes = 30
"#,
        )
        .expect("parse");
        assert_eq!(
            cfg.session.focus,
            Some(Action::Shell {
                run: "focus.sh".into()
            })
        );
        assert_eq!(
            cfg.session.ttl(),
            Some(std::time::Duration::from_secs(30 * 60))
        );
    }

    #[test]
    fn session_ttl_defaults_and_never() {
        // Missing => 60 minutes.
        assert_eq!(
            Config::default().session.ttl(),
            Some(std::time::Duration::from_secs(60 * 60))
        );
        // 0 => never.
        let cfg = Config::from_toml("[session]\nttl_minutes = 0\n").expect("parse");
        assert_eq!(cfg.session.ttl(), None);
    }

    #[test]
    fn tombstone_ttl_defaults_and_never() {
        // Missing => 30 minutes.
        assert_eq!(
            Config::default().session.tombstone_ttl(),
            Some(std::time::Duration::from_secs(30 * 60))
        );
        // 0 => never — the user who commissioned this feature wants exactly
        // this, personally, for sessions left through a reboot.
        let cfg = Config::from_toml("[session]\ntombstone_ttl_minutes = 0\n").expect("parse");
        assert_eq!(cfg.session.tombstone_ttl(), None);
        // A configured value round-trips.
        let cfg = Config::from_toml("[session]\ntombstone_ttl_minutes = 90\n").expect("parse");
        assert_eq!(
            cfg.session.tombstone_ttl(),
            Some(std::time::Duration::from_secs(90 * 60))
        );
    }

    #[test]
    fn style_override_applies_over_defaults() {
        let cfg = Config::from_toml(
            r#"
[styles.waiting]
rgb = [1, 2, 3]
pattern = "strobe"
period_ms = 123
"#,
        )
        .expect("parse");
        let table = cfg.style_table();
        // Overridden state (period clamped 100..=5000, 123 stays).
        assert_eq!(
            table.get(State::Waiting),
            Style::new([1, 2, 3], Pattern::Strobe, 123)
        );
        // Untouched state keeps its default.
        assert_eq!(table.get(State::Error), default_style(State::Error));
    }

    #[test]
    fn style_override_missing_period_uses_state_default() {
        let cfg = Config::from_toml(
            r#"
[styles.running]
rgb = [10, 20, 30]
pattern = "solid"
"#,
        )
        .expect("parse");
        let table = cfg.style_table();
        assert_eq!(
            table.get(State::Running).period_ms,
            default_style(State::Running).period_ms
        );
    }

    #[test]
    fn edit_style_toml_preserves_unrelated_content_and_comments() {
        let original = r#"# my focalpoint config
[actions]
accept = { type = "keystroke", keys = "enter" }  # inline comment

[dial]
mode = "shell"
cw = "echo up"
"#;
        let updated = edit_style_toml(
            original,
            State::Waiting,
            Style::new([30, 144, 255], Pattern::Blink, 800),
        )
        .expect("edit");
        // Everything from the original survives verbatim.
        assert!(updated.starts_with(original));
        // The new section was appended.
        assert!(updated.contains("[styles.waiting]"));
        assert!(updated.contains("rgb = [30, 144, 255]"));
        assert!(updated.contains("pattern = \"blink\""));
        assert!(updated.contains("period_ms = 800"));
        // No bare [styles] header (implicit parent).
        assert!(!updated.contains("\n[styles]\n"));
    }

    #[test]
    fn edit_style_toml_updates_existing_section_in_place() {
        let original = "[styles.waiting]\nrgb = [1, 1, 1]\npattern = \"solid\"\nperiod_ms = 100\n";
        let updated = edit_style_toml(
            original,
            State::Waiting,
            Style::new([9, 9, 9], Pattern::Strobe, 2000),
        )
        .expect("edit");
        assert!(updated.contains("rgb = [9, 9, 9]"));
        assert!(updated.contains("pattern = \"strobe\""));
        assert!(updated.contains("period_ms = 2000"));
        // Reparse to confirm only one waiting entry with the new value.
        let cfg = Config::from_toml(&updated).expect("reparse");
        assert_eq!(cfg.style_table().get(State::Waiting).rgb, [9, 9, 9]);
    }

    #[test]
    fn edit_style_toml_creates_from_empty() {
        let updated = edit_style_toml(
            "",
            State::Error,
            Style::new([242, 64, 64], Pattern::Blink, 250),
        )
        .expect("edit");
        assert!(updated.contains("[styles.error]"));
        assert!(Config::from_toml(&updated).is_ok());
    }

    #[test]
    fn explicit_none_action_parses() {
        let cfg = Config::from_toml(
            r#"[actions]
accept = { type = "none" }
"#,
        )
        .expect("parse");
        assert_eq!(cfg.action_for("accept"), Action::None);
    }
}
