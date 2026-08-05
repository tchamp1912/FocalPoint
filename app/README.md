# FocalPoint menu-bar app

A native macOS menu-bar app (menu-bar only, no Dock icon) for
[FocalPoint](../PLAN.md). It replaces the earlier Hammerspoon rig: it shows live
agent-session state, gives you global hotkeys for the agent loop, and lets you
edit the per-state render styles — all over the `focalpointd` unix-socket protocol
([`PROTOCOL.md`](../PROTOCOL.md)).

- Menu-bar item: a neutral **keyboard** template icon (deliberately not a
  colored dot). A numeric **attention badge** appears when any session is
  `waiting`, `approval`, or `error`.
- Dropdown: one row per live session (slot, kind, label, state + color swatch,
  time since last change), an aggregate + connection header, and Settings/Quit.
- **Rename a session**: right-click any session row (dropdown or desktop
  widget) → *Rename…*. The row becomes a text field; Return saves, Esc
  cancels. The field edits the *override*, so it starts empty and shows the
  adapter's own label as its placeholder — submit it empty to drop the
  rename and go back to that label. Names last as long as the session (see
  `rename-session` in [`PROTOCOL.md`](../PROTOCOL.md) §3).
- **Move to Slot**: right-click a session → *Move to Slot* to place it on
  any free numbered slot (`move-slot` — sparse placement; the gap stays
  until a session ends or is parked, which compacts) or to swap slots with
  another session (`swap-slots`). Offered for live, active sessions in the
  dropdown and the widget.
- Settings window: per-state style editor (color, pattern, period) and
  behavior toggles.
- Floating **desktop widget**: a draggable HUD mirroring the aggregate state
  and sessions, with clickable rows (click focuses the session). Two
  orientations — a vertical card or a wide horizontal strip with compact
  session cells — selectable in Settings → Behavior → Orientation or the
  widget's right-click menu. Drag the bottom-right corner grip to set its
  width (height always fits the content; horizontal cells scroll when they
  overflow a pinned width); widths are remembered per orientation, and
  *Reset Widget Width* (context menu or Settings) returns to automatic
  sizing. Content changes re-anchor the window on the screen edge it's
  parked nearest, so sessions arriving/leaving never make it jump. A
  **Compact Rows** toggle (same two places) collapses each session to one
  line by hiding its stats row and context meter.
- **Session backlog**: right-click a session (dropdown or widget) → *Move to
  Backlog* to park it without ending it (`set-session-backlogged`,
  PROTOCOL.md §3). Parked sessions keep reporting and stay clickable — a
  click still bounces focus to them by id — but they release their numbered
  key, leave the aggregate/attention routing and the menu-bar badge count,
  and move to a labeled Backlog section: below the active list in the
  dropdown and vertical widget, trailing it in the horizontal strip. *Move
  to Active* brings one back (lowest free slot, or slotless overflow when
  all 12 are taken). Requires a backlog-aware daemon; against an older one
  the menu items silently no-op.
- Global hotkeys via Carbon (no Accessibility permission needed).

Requires **macOS 14+, Apple Silicon**.

### Text input in these windows (non-obvious)

Adding any editable field to the dropdown or the desktop widget needs four
things, and none of them hold by default — `@FocusState` alone silently
produces a field that renders and ignores every keystroke:

1. **Don't put it inside a disabled view.** `.disabled()` propagates to the
   whole subtree, so disabling a row's `Button` to suppress its tap action
   also disables any field inside that button's label. Render the editing row
   *outside* the `Button` instead (see `sessionList` in `MenuContentView`).
2. **Activate the app.** This is an `LSUIElement` / `.accessory` app, so
   clicking its panels never makes it the active app and key events keep
   going to whatever you were typing in before.
3. **Let the window become key.** `NSWindow.canBecomeKey` is hardcoded false
   for borderless windows, and the widget is `[.borderless,
   .nonactivatingPanel]` — hence `KeyablePanel` in `DesktopOverlay.swift`.
4. **Then** request view-level focus, on a later runloop turn: keying a
   window resets its first responder.

Steps 2–4 are handled by `takeKeyboardFocus` in `Materials.swift`.

## Build

```sh
cd app
./build.sh
```

`build.sh` compiles all `Sources/*.swift` with `swiftc -O` (arm64, macOS 14
target), assembles `FocalPoint.app`, and ad-hoc-codesigns it
(`codesign --force --deep -s -`) so it launches without Gatekeeper prompts.
No Xcode project and no SPM manifest are required — just the Xcode Command Line
Tools.

### Liquid Glass

The dropdown, desktop widget, and settings cards render with **Liquid Glass**
(`glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`) — see
[`Sources/Glass.swift`](Sources/Glass.swift).

That API is macOS 26 only and is *absent from older SDKs*, so it can't just be
`if #available`-guarded — it wouldn't compile. `build.sh` checks
`xcrun --show-sdk-version` and defines `FOCALPOINT_LIQUID_GLASS` only when the
active SDK is 26+, printing which path it took:

```
==> SDK 26.0: Liquid Glass enabled
==> SDK 14.4: Liquid Glass needs the macOS 26 SDK — building with the standard materials
```

So getting the glass needs **both** macOS 26 *and* the matching Xcode /
Command Line Tools — updating the OS alone leaves an older SDK selected and
the build stays on the fallback. Check with `xcrun --show-sdk-version`, and
`sudo xcode-select -s` the newer toolchain if it reports an old one.

The deployment target stays macOS 14 regardless, so a binary built on the new
SDK still runs on 14/15 and falls back at runtime via
`if #available(macOS 26.0, *)`. The fallback is the app's plain
`NSVisualEffectView` materials, deliberately not a hand-rolled imitation of
glass — faking it out of blurs and white gradients reads as washed-out haze.

## Install

Either copy the bundle to Applications:

```sh
cp -R FocalPoint.app /Applications/
open /Applications/FocalPoint.app
```

or run it in place:

```sh
open ./FocalPoint.app
```

The icon appears in the menu bar. There is no Dock icon or main window
(`LSUIElement`).

To see connection logs, run the executable directly instead of `open`:

```sh
./FocalPoint.app/Contents/MacOS/FocalPoint        # logs to stderr
FOCALPOINT_DEBUG=1 ./FocalPoint.app/Contents/MacOS/FocalPoint   # also logs every event
```

## Launch at login

There is no bundled installer for a login item. Add it manually:

1. **System Settings → General → Login Items**.
2. Under *Open at Login*, click **+**, and choose `FocalPoint.app`
   (in `/Applications` or wherever you keep it).

## Hotkeys

All hotkeys use **Control + Option** as the modifier. They are injected through
the daemon (`inject`) — the same dispatch path as real hardware — so they work
without granting Accessibility permission. Toggle them all off in Settings.

| Shortcut        | Action                                             |
|-----------------|----------------------------------------------------|
| ⌃⌥1 … ⌃⌥9       | Focus session in slot 1–9 (`inject key key<N> tap`)|
| ⌃⌥A             | Accept (`inject key accept tap`)                   |
| ⌃⌥R             | Reject (`inject key reject tap`)                    |
| ⌃⌥N             | New task (`inject key new-task tap`)               |
| ⌃⌥Space         | Push-to-talk (`press` on key-down, `release` on key-up) |
| ⌃⌥=             | Dial +1 (`inject dial 1`)                          |
| ⌃⌥-             | Dial −1 (`inject dial -1`)                         |

## Settings

Open **Settings** from the dropdown footer.

**Behavior**

- **Enable global hotkeys** (default ON) — registers/unregisters the table above.
- **Show desktop overlay** (default ON) — the transparent desktop HUD.
- **Colored status icon** (default OFF) — tints the menu-bar icon/badge by the
  aggregate state instead of the neutral template.

**State styles** — one row per state (`idle`, `thinking`, `running`, `waiting`,
`approval`, `done`, `error`, `compacting`):

- **Color** (`ColorPicker`), **Pattern** (`solid / breathe / blink / strobe /
  off`), **Period** (100–5000 ms slider, debounced).
- Loaded from the daemon's `get-styles` on connect; each edit sends `set-style`,
  which the daemon persists and broadcasts.
- **Reset to defaults** re-sends the `PROTOCOL.md` §1 defaults.
- If the daemon is older and doesn't support styles, edits are kept locally and
  a caption says so; the editor still works.

**Usage monitor**

- The menu and desktop widget show last-known provider quota percent and reset
  times when enabled in **Claude & Codex** settings.
- Claude Code data comes from its documented status-line `rate_limits` fields;
  see `adapters/claude-code/README.md` to opt in. The reporter sends only four
  numeric limit fields to the local daemon.
- Codex is opt-in. The app starts a local `codex app-server` and calls its
  supported `account/rateLimits/read` API using existing ChatGPT auth.
- API-billed OpenAI usage is also supported for organization owners: launch
  FocalPoint with `OPENAI_ADMIN_KEY` set. It reads the official Organization
  Costs endpoint and shows the current UTC day's spend as a separate **OpenAI
  API** record. The key is neither persisted nor sent to the daemon. Ordinary
  API/project keys cannot read organization billing, so they intentionally do
  not enable this monitor.
- API-billed Claude usage is supported with `ANTHROPIC_ADMIN_KEY`, which shows
  the current UTC day's exact input/output tokens and cost from Anthropic's
  Admin Usage and Cost APIs.
- Cursor teams can set `CURSOR_ADMIN_API_KEY` to show the documented Admin API
  current-cycle spend. Individual Cursor API keys intentionally cannot access
  the team billing report.

## How it maps to the protocol

- On connect the app sends `subscribe` and consumes the snapshot + live stream:
  `state` → aggregate, `session` → session rows, `session-ended` → removal,
  `style` → swatch colors, and `usage` → account-quota meters. It also issues
  one-shot `get-styles` / `list-sessions` / `get-usage` requests to seed state
  and detect daemon capabilities.
- It auto-reconnects every 2 s and shows an **Offline** indicator when the
  daemon is down.
- Against an older daemon that emits only aggregate `state` events, it degrades
  to an aggregate-only display ("no sessions" + aggregate).
- Clicking a session row sends `inject key key<slot> tap` (focus/bounce).
- Renaming sends `rename-session`; the row updates optimistically and the
  daemon's `session` broadcast confirms it. Against a daemon too old to know
  the command, the rename simply reverts on the session's next state change.

MIT License.
