//! `focalpoint` — thin CLI client over the daemon socket (PROTOCOL.md §4).
//! Also runs the daemon via `focalpoint daemon`.

use clap::{Parser, Subcommand};
use focalpoint::client;
use focalpoint::daemon::{self, DaemonOpts};

#[derive(Parser, Debug)]
#[command(
    name = "focalpoint",
    about = "Control the FocalPoint macropad: set agent state, drive LEDs, watch events."
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Set the agent state (drives the LEDs). With --session, registers/updates
    /// that session; without, sets the sessionless default.
    SetState {
        /// idle | thinking | running | waiting | done | error
        state: String,
        /// Session id (implicitly registers the session on first sight).
        #[arg(long)]
        session: Option<String>,
        /// Tool identifier: claude | codex | openrouter | ...
        #[arg(long)]
        kind: Option<String>,
        /// Human-readable label for the session.
        #[arg(long)]
        label: Option<String>,
        /// Working directory (populates meta.cwd).
        #[arg(long)]
        cwd: Option<String>,
        /// Extra meta key=value pair (repeatable). Numeric values are stored
        /// as numbers; adapters use this for optional per-session stats like
        /// tokens_in/tokens_out/tool_calls/turns (see PROTOCOL.md §3).
        #[arg(long = "meta", value_name = "KEY=VALUE")]
        meta: Vec<String>,
    },
    /// Record a provider-wide account usage snapshot. Values must be numeric.
    SetUsage {
        /// Provider identifier, e.g. claude or codex.
        provider: String,
        /// Numeric usage key=value pair (repeatable).
        #[arg(long = "meta", value_name = "KEY=VALUE")]
        meta: Vec<String>,
    },
    /// Print provider-wide account usage snapshots.
    Usage {
        /// Emit compact JSON.
        #[arg(long)]
        json: bool,
    },
    /// Print the current aggregate state.
    GetState,
    /// List live sessions in slot order.
    Sessions {
        /// Emit the raw JSON array instead of a table.
        #[arg(long)]
        json: bool,
    },
    /// Rename a session (omit NAME to clear it and fall back to the label).
    RenameSession {
        /// Session id.
        id: String,
        /// New display name. Omit or pass "" to clear.
        name: Option<String>,
    },
    /// End a session by id.
    EndSession {
        /// Session id.
        id: String,
    },
    /// Override an LED (or all) to an RGB color.
    SetLed {
        /// LED index, or "all".
        index: String,
        r: u8,
        g: u8,
        b: u8,
    },
    /// List the per-state render styles.
    Styles {
        /// Emit the raw JSON object instead of a table.
        #[arg(long)]
        json: bool,
    },
    /// Override a state's render style (persists to config.toml).
    SetStyle {
        /// idle | thinking | running | waiting | done | error
        state: String,
        r: u8,
        g: u8,
        b: u8,
        /// solid | breathe | blink | strobe | off
        pattern: String,
        /// Animation period in ms (clamped 100..=5000; defaults per state).
        period_ms: Option<u16>,
    },
    /// Stream device events as NDJSON to stdout.
    Watch,
    /// Exit 0 if the daemon and a device are both up.
    Ping,
    /// Feed a synthetic device event through the daemon (actions fire,
    /// subscribers see it), as if it came from real hardware.
    Inject {
        #[command(subcommand)]
        what: InjectKind,
    },
    /// Run the daemon (alias for `focalpointd`).
    Daemon {
        /// Simulate a device (see `focalpointd --mock-device`).
        #[arg(long)]
        mock_device: bool,
    },
}

#[derive(Subcommand, Debug)]
enum InjectKind {
    /// Synthetic key event.
    Key {
        /// Control name: accept, reject, new-task, push-to-talk, dial-press, key1..key12.
        control: String,
        /// press | release | tap (tap = press then release).
        action: String,
    },
    /// Synthetic dial delta (signed; clockwise positive).
    Dial {
        /// e.g. 2 or -1. Negative values are accepted directly.
        #[arg(allow_hyphen_values = true)]
        delta: i64,
    },
    /// Synthetic joystick gesture: north | east | south | west | press.
    Joy { gesture: String },
}

fn main() {
    let cli = Cli::parse();

    // `daemon` runs the async server; everything else is a synchronous client.
    if let Cmd::Daemon { mock_device } = cli.cmd {
        let rt = match tokio::runtime::Runtime::new() {
            Ok(rt) => rt,
            Err(e) => {
                eprintln!("focalpoint: failed to start runtime: {e}");
                std::process::exit(1);
            }
        };
        if let Err(e) = rt.block_on(daemon::run(DaemonOpts { mock_device })) {
            eprintln!("focalpoint: {e}");
            std::process::exit(1);
        }
        return;
    }

    let result = match cli.cmd {
        Cmd::SetState {
            state,
            session,
            kind,
            label,
            cwd,
            meta,
        } => client::set_state(
            &state,
            session.as_deref(),
            kind.as_deref(),
            label.as_deref(),
            cwd.as_deref(),
            &meta,
        ),
        Cmd::SetUsage { provider, meta } => client::set_usage(&provider, &meta),
        Cmd::Usage { json } => client::usage(json),
        Cmd::GetState => client::get_state(),
        Cmd::Sessions { json } => client::sessions(json),
        Cmd::RenameSession { id, name } => client::rename_session(&id, name.as_deref()),
        Cmd::EndSession { id } => client::end_session(&id),
        Cmd::SetLed { index, r, g, b } => client::set_led(&index, r, g, b),
        Cmd::Styles { json } => client::styles(json),
        Cmd::SetStyle {
            state,
            r,
            g,
            b,
            pattern,
            period_ms,
        } => client::set_style(&state, r, g, b, &pattern, period_ms),
        Cmd::Watch => client::watch(),
        Cmd::Ping => client::ping(),
        Cmd::Inject { what } => match what {
            InjectKind::Key { control, action } => client::inject_key(&control, &action),
            InjectKind::Dial { delta } => client::inject_dial(delta),
            InjectKind::Joy { gesture } => client::inject_joy(&gesture),
        },
        Cmd::Daemon { .. } => unreachable!("handled above"),
    };

    if let Err(e) = result {
        eprintln!("focalpoint: {}", e.message);
        std::process::exit(e.code);
    }
}
