# App exits caused by broken pipes — September 13, 2026

macOS launchd records repeated FocalPoint app exits with signal 13 (`SIGPIPE`).
Examples in local time (America/New_York): 19:56:35, 20:24:13, 20:25:44,
21:13:28, and 21:20:35. Several runs lasted approximately 60 or 120 seconds,
matching the enabled Codex quota monitor's refresh interval. These were app
process exits; the daemon stayed running. The app log ends abruptly and there
is no ordinary FocalPoint crash report.

The code had three exposed writes: the quota monitor's app-server stdin pipe,
daemon sockets, and diagnostic stderr. A peer exiting before a write can cause
SIGPIPE before the error path runs. The quota monitor additionally launched
Codex through ambient GUI PATH and used a blocking read despite a nominal
five-second deadline. The OS records establish the signal, but do not include
a stack identifying which write generated each individual exit.

The fix suppresses SIGPIPE on the owned descriptors and handles write errors,
without changing signal handling globally. The quota probe uses explicit
executable discovery, bounded IO and cleanup. Lifecycle logs now record the
app PID and normal termination, making future abrupt exits distinguishable.

Validation uses isolated closed-peer sockets/pipes and fake quota processes,
including immediate exit and stalled output; it requires no model task or
credentials. Deployment replaces only the menu-bar app and leaves the running
daemon and managed terminals intact.

The regression suite includes an unprotected SIGPIPE control, closed daemon
socket, closed stderr and pipe, child exit before/during handshake, successful
RPC exchange, stderr flooding, stalled and partial output, output-size limits,
a child ignoring SIGTERM, child-process cleanup, and file-descriptor stability.
Both transport suites and the full Swift app typecheck pass.

Installed-app smoke check: the signed replacement remained alive with the
same PID while two live Codex quota refresh events arrived after the initial
subscription snapshot. The daemon was not restarted. This verifies the
previously implicated periodic path over multiple cycles, not indefinite
uptime.
