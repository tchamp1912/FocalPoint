//! Per-state render styles (PROTOCOL.md §3 Styles).
//!
//! A [`Style`] is `rgb` + [`Pattern`] + `period_ms` (clamped 100–5000). Every
//! state always has a style; unset states use the §1-table defaults. The
//! [`StyleTable`] holds all six and is the runtime source of truth.

use crate::protocol::{HostCmd, Pattern, State};

/// Minimum / maximum animation period in ms (PROTOCOL.md §3).
pub const PERIOD_MIN: u16 = 100;
pub const PERIOD_MAX: u16 = 5000;

/// A single state's render style.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Style {
    pub rgb: [u8; 3],
    pub pattern: Pattern,
    pub period_ms: u16,
}

impl Style {
    /// Construct a style, clamping `period_ms` to `[PERIOD_MIN, PERIOD_MAX]`.
    pub fn new(rgb: [u8; 3], pattern: Pattern, period_ms: u16) -> Style {
        Style {
            rgb,
            pattern,
            period_ms: period_ms.clamp(PERIOD_MIN, PERIOD_MAX),
        }
    }

    /// Encode as the device command for `state`.
    pub fn to_host_cmd(&self, state: State) -> HostCmd {
        HostCmd::SetStateStyle {
            state,
            rgb: self.rgb,
            pattern: self.pattern,
            period_ms: self.period_ms,
        }
    }
}

/// The default style for a state (PROTOCOL.md §1 table).
pub fn default_style(state: State) -> Style {
    match state {
        State::Idle => Style::new([40, 40, 40], Pattern::Breathe, 4000),
        State::Thinking => Style::new([158, 89, 242], Pattern::Breathe, 2500),
        State::Running => Style::new([255, 166, 26], Pattern::Breathe, 800),
        State::Waiting => Style::new([64, 140, 255], Pattern::Blink, 800),
        State::Done => Style::new([51, 204, 89], Pattern::Solid, 1000),
        State::Error => Style::new([242, 64, 64], Pattern::Blink, 250),
        // Slate/lavender grey — distinct from idle's plain dim white so the
        // two don't read as identical at a glance, but still deliberately
        // muted (not one of the "real work" colors) since it's transient
        // bookkeeping, not agent activity (PROTOCOL.md §1).
        State::Compacting => Style::new([110, 110, 140], Pattern::Breathe, 3000),
    }
}

/// All seven styles, indexed by state id.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StyleTable {
    styles: [Style; 7],
}

impl Default for StyleTable {
    fn default() -> Self {
        StyleTable {
            styles: [
                default_style(State::Idle),
                default_style(State::Thinking),
                default_style(State::Running),
                default_style(State::Waiting),
                default_style(State::Done),
                default_style(State::Error),
                default_style(State::Compacting),
            ],
        }
    }
}

impl StyleTable {
    pub fn get(&self, state: State) -> Style {
        self.styles[state.id() as usize]
    }

    pub fn set(&mut self, state: State, style: Style) {
        self.styles[state.id() as usize] = style;
    }

    /// Iterate `(state, style)` in state-id order (idle..compacting).
    pub fn iter(&self) -> impl Iterator<Item = (State, Style)> + '_ {
        (0..7u8).map(move |i| (State::from_id(i).unwrap(), self.styles[i as usize]))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn period_is_clamped() {
        assert_eq!(Style::new([0, 0, 0], Pattern::Blink, 10).period_ms, PERIOD_MIN);
        assert_eq!(
            Style::new([0, 0, 0], Pattern::Blink, 60000).period_ms,
            PERIOD_MAX
        );
        assert_eq!(Style::new([0, 0, 0], Pattern::Blink, 800).period_ms, 800);
    }

    #[test]
    fn defaults_match_protocol_table() {
        let t = StyleTable::default();
        assert_eq!(
            t.get(State::Waiting),
            Style::new([64, 140, 255], Pattern::Blink, 800)
        );
        assert_eq!(
            t.get(State::Error),
            Style::new([242, 64, 64], Pattern::Blink, 250)
        );
        // iter yields all seven in id order.
        let states: Vec<State> = t.iter().map(|(s, _)| s).collect();
        assert_eq!(
            states,
            vec![
                State::Idle,
                State::Thinking,
                State::Running,
                State::Waiting,
                State::Done,
                State::Error,
                State::Compacting,
            ]
        );
    }

    #[test]
    fn set_and_get_roundtrip() {
        let mut t = StyleTable::default();
        let s = Style::new([1, 2, 3], Pattern::Strobe, 500);
        t.set(State::Idle, s);
        assert_eq!(t.get(State::Idle), s);
    }
}
