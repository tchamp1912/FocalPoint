//! FocalPoint wire protocol (PROTOCOL.md §1 and §2).
//!
//! This module is pure data: state names/IDs, the USB Raw HID report layout,
//! and encode/decode helpers. It has no I/O so it is trivially unit-testable.

/// Protocol version advertised in `PING`/`PONG`.
pub const PROTO_MAJOR: u8 = 0;
pub const PROTO_MINOR: u8 = 3;

/// QMK Raw HID reports are 32 bytes (PROTOCOL.md §2).
pub const REPORT_LEN: usize = 32;

/// Device matching (PROTOCOL.md §2).
pub const USAGE_PAGE: u16 = 0xFF60;
pub const USAGE: u16 = 0x61;
pub const VID: u16 = 0xFEED;
pub const PID: u16 = 0x5642;

// Host -> device command IDs (byte 0).
pub const CMD_PING: u8 = 0x00;
pub const CMD_SET_STATE: u8 = 0x01;
pub const CMD_SET_LED: u8 = 0x02;
pub const CMD_SET_HOST_MODE: u8 = 0x03;
pub const CMD_SET_KEY_STATE: u8 = 0x04;
pub const CMD_SET_STATE_STYLE: u8 = 0x05;
pub const CMD_SET_NAV_STATE: u8 = 0x06;

/// Sentinel state byte for `SET_KEY_STATE` meaning "slot empty" (PROTOCOL.md §2).
pub const KEY_STATE_EMPTY: u8 = 0xFF;

// Device -> host command IDs (byte 0).
pub const CMD_PONG: u8 = 0x80;
pub const CMD_KEY_EVENT: u8 = 0x81;
pub const CMD_DIAL: u8 = 0x82;
pub const CMD_JOY: u8 = 0x83;

/// Canonical agent states (PROTOCOL.md §1). JSON/CLI names are the lowercase
/// forms here (`running`, not `running-tool`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Idle,
    Thinking,
    Running,
    Waiting,
    Done,
    Error,
    /// Transient: a Claude Code session is between a `PreCompact` hook and
    /// its post-compaction continuation claiming the slot (see
    /// `Registry::set_state`'s rekey-by-cwd/tty match in session.rs). Never
    /// set directly by a user-facing action; not part of the original
    /// PROTOCOL.md v0.1 six-state table, added additively in v0.2 as id 6 so
    /// older firmware/clients that don't recognize it simply fail
    /// `from_id`/`from_name` rather than misrendering it as another state.
    Compacting,
    /// A Claude Code permission prompt awaiting an explicit user decision.
    /// This is intentionally distinct from `Waiting`, which means ordinary
    /// user input is needed. Added additively in protocol v0.3.
    Approval,
}

impl State {
    pub fn id(self) -> u8 {
        match self {
            State::Idle => 0,
            State::Thinking => 1,
            State::Running => 2,
            State::Waiting => 3,
            State::Done => 4,
            State::Error => 5,
            State::Compacting => 6,
            State::Approval => 7,
        }
    }

    pub fn from_id(id: u8) -> Option<State> {
        Some(match id {
            0 => State::Idle,
            1 => State::Thinking,
            2 => State::Running,
            3 => State::Waiting,
            4 => State::Done,
            5 => State::Error,
            6 => State::Compacting,
            7 => State::Approval,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            State::Idle => "idle",
            State::Thinking => "thinking",
            State::Running => "running",
            State::Waiting => "waiting",
            State::Done => "done",
            State::Error => "error",
            State::Compacting => "compacting",
            State::Approval => "approval",
        }
    }

    pub fn from_name(name: &str) -> Option<State> {
        Some(match name {
            "idle" => State::Idle,
            "thinking" => State::Thinking,
            "running" => State::Running,
            "waiting" => State::Waiting,
            "done" => State::Done,
            "error" => State::Error,
            "compacting" => State::Compacting,
            "approval" => State::Approval,
            _ => return None,
        })
    }

    /// Aggregation priority (PROTOCOL.md §3): the worst state across live
    /// sessions wins, ordered `error > approval > waiting > running > thinking
    /// > done > compacting > idle`. Note this differs from the numeric
    /// [`id`](State::id) ordering (`done`/`error` are swapped relative to
    /// severity). `compacting` sits just above `idle` — deliberately the
    /// lowest non-idle priority, since it's bookkeeping (a session between
    /// identities, not doing agent work) and must never make the aggregate
    /// (or another session's own key) look alarming while it waits, typically
    /// under a second, to be reunited with its continuation.
    pub fn priority(self) -> u8 {
        match self {
            State::Idle => 0,
            State::Compacting => 1,
            State::Done => 2,
            State::Thinking => 3,
            State::Running => 4,
            State::Waiting => 5,
            State::Approval => 6,
            State::Error => 7,
        }
    }
}

/// Render pattern for a state style (PROTOCOL.md §2 `SET_STATE_STYLE`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pattern {
    Solid,
    Breathe,
    Blink,
    Strobe,
    Off,
}

impl Pattern {
    pub fn id(self) -> u8 {
        match self {
            Pattern::Solid => 0,
            Pattern::Breathe => 1,
            Pattern::Blink => 2,
            Pattern::Strobe => 3,
            Pattern::Off => 4,
        }
    }

    pub fn from_id(id: u8) -> Option<Pattern> {
        Some(match id {
            0 => Pattern::Solid,
            1 => Pattern::Breathe,
            2 => Pattern::Blink,
            3 => Pattern::Strobe,
            4 => Pattern::Off,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            Pattern::Solid => "solid",
            Pattern::Breathe => "breathe",
            Pattern::Blink => "blink",
            Pattern::Strobe => "strobe",
            Pattern::Off => "off",
        }
    }

    pub fn from_name(name: &str) -> Option<Pattern> {
        Some(match name {
            "solid" => Pattern::Solid,
            "breathe" => Pattern::Breathe,
            "blink" => Pattern::Blink,
            "strobe" => Pattern::Strobe,
            "off" => Pattern::Off,
            _ => return None,
        })
    }
}

/// A command we send to the device.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostCmd {
    Ping,
    SetState(State),
    SetLed {
        index: u8,
        r: u8,
        g: u8,
        b: u8,
    },
    SetHostMode(bool),
    /// Per-key session state. `key` is the 1..=12 numbered key (slot). `state`
    /// is `None` to empty the slot (`0xFF`), else that session's state.
    SetKeyState {
        key: u8,
        state: Option<State>,
    },
    /// Override a state's render style (PROTOCOL.md §2). `period_ms` is
    /// little-endian in the report.
    SetStateStyle {
        state: State,
        rgb: [u8; 3],
        pattern: Pattern,
        period_ms: u16,
    },
    SetNavState(Option<State>),
}

impl HostCmd {
    /// Encode into a 32-byte Raw HID report. The device write path prepends the
    /// platform report-ID byte (0x00); this is the QMK payload itself.
    pub fn encode(&self) -> [u8; REPORT_LEN] {
        let mut buf = [0u8; REPORT_LEN];
        match *self {
            HostCmd::Ping => {
                buf[0] = CMD_PING;
                buf[1] = PROTO_MAJOR;
                buf[2] = PROTO_MINOR;
            }
            HostCmd::SetState(state) => {
                buf[0] = CMD_SET_STATE;
                buf[1] = state.id();
            }
            HostCmd::SetLed { index, r, g, b } => {
                buf[0] = CMD_SET_LED;
                buf[1] = index;
                buf[2] = r;
                buf[3] = g;
                buf[4] = b;
            }
            HostCmd::SetHostMode(on) => {
                buf[0] = CMD_SET_HOST_MODE;
                buf[1] = u8::from(on);
            }
            HostCmd::SetKeyState { key, state } => {
                buf[0] = CMD_SET_KEY_STATE;
                buf[1] = key;
                buf[2] = state.map_or(KEY_STATE_EMPTY, |s| s.id());
            }
            HostCmd::SetStateStyle {
                state,
                rgb,
                pattern,
                period_ms,
            } => {
                buf[0] = CMD_SET_STATE_STYLE;
                buf[1] = state.id();
                buf[2] = rgb[0];
                buf[3] = rgb[1];
                buf[4] = rgb[2];
                buf[5] = pattern.id();
                // little-endian u16 period
                buf[6] = (period_ms & 0xFF) as u8;
                buf[7] = (period_ms >> 8) as u8;
            }
            HostCmd::SetNavState(state) => {
                buf[0] = CMD_SET_NAV_STATE;
                buf[1] = state.map_or(KEY_STATE_EMPTY, |s| s.id());
            }
        }
        buf
    }
}

/// A raw event decoded from a device report.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeviceEvent {
    Pong { major: u8, minor: u8, keys: u8 },
    Key { control: u8, pressed: bool },
    Dial { delta: i8 },
    Joy { gesture: u8 },
}

impl DeviceEvent {
    /// Decode a report from the device. Returns `None` for unknown/short frames.
    pub fn decode(buf: &[u8]) -> Option<DeviceEvent> {
        let cmd = *buf.first()?;
        match cmd {
            CMD_PONG => Some(DeviceEvent::Pong {
                major: *buf.get(1)?,
                minor: *buf.get(2)?,
                keys: *buf.get(3)?,
            }),
            CMD_KEY_EVENT => Some(DeviceEvent::Key {
                control: *buf.get(1)?,
                pressed: *buf.get(2)? != 0,
            }),
            CMD_DIAL => Some(DeviceEvent::Dial {
                delta: *buf.get(1)? as i8,
            }),
            CMD_JOY => Some(DeviceEvent::Joy {
                gesture: *buf.get(1)?,
            }),
            _ => None,
        }
    }
}

/// Map a `KEY_EVENT` control ID to its stable name (PROTOCOL.md §2 control IDs).
pub fn control_name(id: u8) -> String {
    match id {
        0 => "accept".to_string(),
        1 => "reject".to_string(),
        2 => "new-task".to_string(),
        3 => "push-to-talk".to_string(),
        4..=15 => format!("key{}", id - 3), // 4 => key1 .. 15 => key12
        16 => "dial-press".to_string(),
        17 => "attention-next".to_string(),
        18 => "attention-prev".to_string(),
        19 => "session-next".to_string(),
        20 => "session-prev".to_string(),
        other => format!("control{other}"),
    }
}

/// Inverse of [`control_name`]. Used by the mock device injector and by config.
pub fn control_id(name: &str) -> Option<u8> {
    match name {
        "accept" => Some(0),
        "reject" => Some(1),
        "new-task" => Some(2),
        "push-to-talk" => Some(3),
        "dial-press" => Some(16),
        "attention-next" => Some(17),
        "attention-prev" => Some(18),
        "session-next" => Some(19),
        "session-prev" => Some(20),
        _ => {
            let n: u8 = name.strip_prefix("key")?.parse().ok()?;
            if (1..=12).contains(&n) {
                Some(n + 3)
            } else {
                None
            }
        }
    }
}

/// Map a `JOY` gesture ID to its JSON name.
pub fn joy_name(gesture: u8) -> &'static str {
    match gesture {
        0 => "north",
        1 => "east",
        2 => "south",
        3 => "west",
        4 => "press",
        _ => "unknown",
    }
}

/// Inverse of [`joy_name`].
pub fn joy_id(name: &str) -> Option<u8> {
    Some(match name {
        "north" => 0,
        "east" => 1,
        "south" => 2,
        "west" => 3,
        "press" => 4,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_state_encodes_command_and_id() {
        let buf = HostCmd::SetState(State::Running).encode();
        assert_eq!(buf[0], CMD_SET_STATE);
        assert_eq!(buf[1], 2);
        assert_eq!(buf.len(), 32);
        assert!(buf[2..].iter().all(|&b| b == 0));
    }

    #[test]
    fn approval_is_an_additive_distinct_state() {
        assert_eq!(State::Approval.id(), 7);
        assert_eq!(State::from_id(7), Some(State::Approval));
        assert_eq!(State::from_name("approval"), Some(State::Approval));
        assert!(State::Approval.priority() > State::Waiting.priority());
    }

    #[test]
    fn set_led_encodes_index_and_rgb() {
        let buf = HostCmd::SetLed {
            index: 0xFF,
            r: 255,
            g: 0,
            b: 128,
        }
        .encode();
        assert_eq!(&buf[0..5], &[CMD_SET_LED, 0xFF, 255, 0, 128]);
    }

    #[test]
    fn set_host_mode_encodes_bool() {
        assert_eq!(HostCmd::SetHostMode(true).encode()[1], 1);
        assert_eq!(HostCmd::SetHostMode(false).encode()[1], 0);
    }

    #[test]
    fn set_key_state_encodes_slot_and_state() {
        let buf = HostCmd::SetKeyState {
            key: 3,
            state: Some(State::Running),
        }
        .encode();
        assert_eq!(&buf[0..3], &[CMD_SET_KEY_STATE, 3, 2]);
        // None => 0xFF (slot empty)
        let empty = HostCmd::SetKeyState {
            key: 3,
            state: None,
        }
        .encode();
        assert_eq!(&empty[0..3], &[CMD_SET_KEY_STATE, 3, KEY_STATE_EMPTY]);
    }

    #[test]
    fn set_nav_state_encodes_next_attention_or_empty() {
        let waiting = HostCmd::SetNavState(Some(State::Waiting)).encode();
        assert_eq!(&waiting[0..2], &[CMD_SET_NAV_STATE, State::Waiting.id()]);
        let empty = HostCmd::SetNavState(None).encode();
        assert_eq!(&empty[0..2], &[CMD_SET_NAV_STATE, KEY_STATE_EMPTY]);
    }

    #[test]
    fn set_state_style_encodes_layout_with_le_period() {
        let buf = HostCmd::SetStateStyle {
            state: State::Waiting,
            rgb: [30, 144, 255],
            pattern: Pattern::Blink,
            period_ms: 800,
        }
        .encode();
        assert_eq!(buf[0], CMD_SET_STATE_STYLE);
        assert_eq!(buf[1], State::Waiting.id()); // 3
        assert_eq!(&buf[2..5], &[30, 144, 255]);
        assert_eq!(buf[5], Pattern::Blink.id()); // 2
                                                 // 800 = 0x0320 => LE bytes 0x20, 0x03
        assert_eq!(buf[6], 0x20);
        assert_eq!(buf[7], 0x03);
        assert_eq!(800u16, u16::from_le_bytes([buf[6], buf[7]]));
    }

    #[test]
    fn pattern_name_id_roundtrip() {
        for id in 0..=4u8 {
            let p = Pattern::from_id(id).unwrap();
            assert_eq!(p.id(), id);
            assert_eq!(Pattern::from_name(p.name()), Some(p));
        }
        assert_eq!(Pattern::from_id(5), None);
        assert_eq!(Pattern::from_name("sparkle"), None);
    }

    #[test]
    fn state_priority_orders_by_severity() {
        use State::*;
        let order = [Idle, Compacting, Done, Thinking, Running, Waiting, Error];
        // Strictly increasing priority in severity order.
        for w in order.windows(2) {
            assert!(w[0].priority() < w[1].priority());
        }
        // Severity differs from numeric id order: done(id 4) < thinking(id 1).
        assert!(Done.priority() < Thinking.priority());
    }

    #[test]
    fn ping_carries_version() {
        let buf = HostCmd::Ping.encode();
        assert_eq!(buf[0], CMD_PING);
        assert_eq!(buf[1], PROTO_MAJOR);
        assert_eq!(buf[2], PROTO_MINOR);
    }

    #[test]
    fn decode_key_event() {
        let mut buf = [0u8; 32];
        buf[0] = CMD_KEY_EVENT;
        buf[1] = 0; // accept
        buf[2] = 1; // pressed
        assert_eq!(
            DeviceEvent::decode(&buf),
            Some(DeviceEvent::Key {
                control: 0,
                pressed: true
            })
        );
    }

    #[test]
    fn decode_dial_is_signed() {
        let mut buf = [0u8; 32];
        buf[0] = CMD_DIAL;
        buf[1] = 0xFF; // -1
        assert_eq!(
            DeviceEvent::decode(&buf),
            Some(DeviceEvent::Dial { delta: -1 })
        );
    }

    #[test]
    fn decode_joy_and_pong() {
        let mut buf = [0u8; 32];
        buf[0] = CMD_JOY;
        buf[1] = 2;
        assert_eq!(
            DeviceEvent::decode(&buf),
            Some(DeviceEvent::Joy { gesture: 2 })
        );

        buf = [0u8; 32];
        buf[0] = CMD_PONG;
        buf[1] = 0;
        buf[2] = 1;
        buf[3] = 13;
        assert_eq!(
            DeviceEvent::decode(&buf),
            Some(DeviceEvent::Pong {
                major: 0,
                minor: 1,
                keys: 13
            })
        );
    }

    #[test]
    fn decode_rejects_unknown_and_empty() {
        assert_eq!(DeviceEvent::decode(&[]), None);
        assert_eq!(DeviceEvent::decode(&[0x42]), None);
    }

    #[test]
    fn state_name_and_id_roundtrip() {
        for id in 0..=7u8 {
            let s = State::from_id(id).unwrap();
            assert_eq!(s.id(), id);
            assert_eq!(State::from_name(s.name()), Some(s));
        }
        assert_eq!(State::from_id(8), None);
        assert_eq!(State::from_name("nope"), None);
    }

    #[test]
    fn control_name_id_roundtrip() {
        let cases = [
            (0u8, "accept"),
            (1, "reject"),
            (2, "new-task"),
            (3, "push-to-talk"),
            (4, "key1"),
            (15, "key12"),
            (16, "dial-press"),
            (17, "attention-next"),
            (18, "attention-prev"),
            (19, "session-next"),
            (20, "session-prev"),
        ];
        for (id, name) in cases {
            assert_eq!(control_name(id), name);
            assert_eq!(control_id(name), Some(id));
        }
        assert_eq!(control_id("key13"), None);
        assert_eq!(control_id("bogus"), None);
    }

    #[test]
    fn joy_name_id_roundtrip() {
        for id in 0..=4u8 {
            assert_eq!(joy_id(joy_name(id)), Some(id));
        }
        assert_eq!(joy_name(9), "unknown");
        assert_eq!(joy_id("nowhere"), None);
    }
}
