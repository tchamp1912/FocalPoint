//! `focalpointd` — the FocalPoint host daemon.

use clap::Parser;
use focalpoint::daemon::{self, DaemonOpts};

#[derive(Parser, Debug)]
#[command(
    name = "focalpointd",
    about = "FocalPoint host daemon: bridges a coding agent to the macropad over USB Raw HID."
)]
struct Args {
    /// Simulate a device: log LED changes and read injected events from stdin
    /// (e.g. `key accept 1`, `dial 2`, `joy north`). No hardware required.
    #[arg(long)]
    mock_device: bool,
}

#[tokio::main]
async fn main() {
    let args = Args::parse();
    if let Err(e) = daemon::run(DaemonOpts {
        mock_device: args.mock_device,
    })
    .await
    {
        eprintln!("focalpointd: {e}");
        std::process::exit(1);
    }
}
