//! FocalPoint host-side library: protocol codec, config model, action execution,
//! the daemon, and the socket client. Binaries `focalpointd` and `focalpoint` are
//! thin shells over these modules.
//!
//! See `PROTOCOL.md` (the wire contract) and `PLAN.md` (project overview).

pub mod actions;
pub mod client;
pub mod config;
pub mod daemon;
pub mod paths;
pub mod protocol;
pub mod session;
pub mod styles;
