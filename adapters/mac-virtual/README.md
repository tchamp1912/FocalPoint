# FocalPoint adapter: mac-virtual

Your MacBook **is** the keyboard until the hardware exists. This adapter turns
the Mac itself into a virtual FocalPoint device for pre-hardware validation of
the whole stack: agent hooks → daemon → "LEDs", and hotkeys → daemon →
actions, exercising exactly the same daemon code paths real hardware will.

Channels:

| Channel | What | Reliability |
|---|---|---|
| FocalPoint menu bar app (`../../app/`) | Session list, focus, style customization, hotkeys | Always works, has color |
| Keyboard backlight (`focalpoint-backlight`) | Brightness patterns per state | Dark rooms only — see caveat |

(An earlier Hammerspoon-based menu-bar dot lived here; it has been replaced by
the native menu bar app in `app/`.)

## Keyboard backlight

```sh
./build.sh                    # swiftc compile (no dependencies)
./focalpoint-backlight run       # renders agent states; Ctrl-C restores settings
```

Patterns (single-color hardware, so brightness stands in for color): slow
pulse = thinking, fast pulse = running, hard blink = waiting, solid = done,
strobe = error.

**Caveats:**
- Uses the private CoreBrightness framework (`KeyboardBrightnessClient`); may
  break in a future macOS release. Verified live on macOS 14 / M2 Air.
- **Idle dimming is the enemy:** macOS zeroes the backlight when you aren't
  typing, instantly cancelling writes. `run` suspends idle dimming for the
  session (and restores it on exit); the suspension is tied to the process,
  which is why the one-shot `set` subcommand doesn't stick — it's a
  diagnostic, not a feature.
- Keyboard ID quirk: `copyKeyboardBacklightIDs` returns an ID that reads but
  rejects writes (on the M2 Air at least); ID `1` is what actually works, so
  the tool write-tests candidates at startup. `isBacklightSuppressedOnKeyboard`
  reads `true` even while the LEDs are controllable — ignore it.
- `run` disables keyboard auto-brightness for the session and restores your
  brightness + auto setting on exit. LEDs are of course only *visible* in a
  dim room, but writes work regardless.

## Menu bar app + hotkeys

Session display, focus/bounce, style customization, and global hotkeys are
provided by the native FocalPoint menu bar app — see `app/README.md` at the repo
root. Everything it does goes through the daemon socket (`focalpoint inject`,
`set-style`, `subscribe`), so it exercises the same daemon code paths real
hardware will.

## What this validates before any PCB exists

- Hook → daemon → renderer latency and state fidelity during real sessions
- Your `config.toml` action mappings (accept/reject/dial/joystick workflows)
- The state model itself (is six states right? does "waiting" grab attention?)

## Limitations vs. real hardware

The backlight is a single status channel (no per-key RGB — it shows the
aggregate state only) and hotkeys steal key combos from other apps. Per-session
display lives in the menu bar app and on real hardware's numbered keys.

MIT License — see `adapters/README.md`.
