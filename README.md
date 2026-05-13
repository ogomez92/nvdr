# nvdr

A terminal client for [NVDA Remote](https://nvdaremote.com/). Connects to an
NVDA Remote relay as the **master** (controller), so you can hear what a
remote NVDA says — printed as plain text in your terminal — and send
keystrokes back to it.

Designed to be run on a VPS over SSH. Cross-platform on the SSH side: works
from any terminal app on Linux, macOS, Windows, or iOS.

## Why

The official NVDA Remote add-on assumes you're running NVDA on Windows. If
you only have a phone or a non-Windows laptop in front of you and need to
help someone with NVDA, your options are limited. With `nvdr` you can SSH
into a Linux box and:

- read the remote screen reader's speech as scrolling text
- send keystrokes (including NVDA commands like NVDA+T) back to the remote
  machine
- copy/paste text into the remote's clipboard

## Install

Requires Rust 1.75+.

```sh
cargo build --release
# binary lands at target/release/nvdr
```

Drop `target/release/nvdr` somewhere on your `$PATH` (`~/.local/bin/nvdr`,
`/usr/local/bin/nvdr`, etc.).

## Quick start

```sh
# Defaults to localhost:6837. Channel key is prompted if not given.
nvdr

# Or fully specified:
nvdr --host relay.example.com --port 6837 --channel 123456789
```

On first connect to a host, `nvdr` pins its TLS certificate fingerprint
(TOFU — Trust On First Use) into `~/.config/nvdr/known_hosts`. On later
connects it verifies the cert against the pin. If the cert ever changes
you'll get an interactive prompt (no need to edit the file). For scripted
use, supply `--fingerprint <sha256-hex>` or `--trust-new-cert`.

The relay uses TLS by default (NVDA Remote's normal behavior — see
`server.py` in NVDARemoteServer). `--insecure` disables verification, only
useful for local testing.

## Using it

Press a key. If it's a normal printable character, an arrow, F-key, Tab,
Enter, Backspace, Esc, or any `Ctrl+letter` — it's forwarded to the remote
NVDA. Even `Ctrl+C`, `Ctrl+Z`, `Ctrl+S` go to the remote, *not* to your
local shell.

Speech from the remote NVDA prints as plain lines:

```
[joined channel 123456789 — 1 peer(s) already connected]
Firefox
Edit, Address and Search bar, edit
https://example.com
```

### Leader shortcuts

A terminal can't send the Insert or Windows keys, so `nvdr` provides a
**leader key** (default **Ctrl+G**, configurable via `--leader`) and a small
table of letter shortcuts that fire useful combos on the remote machine:

| Shortcut             | Sends    | Meaning              |
| -------------------- | -------- | -------------------- |
| `<leader>` `c`       | Alt+F4   | close window         |
| `<leader>` `w`       | NVDA+T   | read window title    |
| `<leader>` `d`       | Win+D    | show desktop         |
| `<leader>` `t`       | Alt+Tab  | switch window        |

More can be added in one line — edit the `SHORTCUTS` table in
`src/leader.rs`. The `combo` column accepts the same syntax as `:k` (see
below), so `alt+f4`, `nvda+t`, `win+shift+s`, etc. all work.

Two other things the leader does:

- `<leader>` `<leader>` — toggle **sticky NVDA modifier**. Every key you
  press afterward is wrapped with NVDA+. Hit `<leader>` `<leader>` again to
  turn it off.
- `<leader>` `:` — open the command prompt.

If the remote NVDA is configured to use CapsLock instead of Insert as its
modifier, type `<leader>` `:` and run `:caps`.

### Sending arbitrary combos (Win+M, Alt+F4, etc.)

Type `<leader>` `:` to enter the command prompt, then:

```
:k win+m              minimize all windows
:k win+d              show desktop
:k win+r              Run dialog
:k alt+f4             close window
:k ctrl+shift+esc     Task Manager
:k win+shift+s        snipping tool
:k nvda+f12           same as <leader> f12
```

Modifiers: `ctrl`, `alt`, `shift`, `win`, `nvda`, `caps`.
Base keys: any letter / digit / punctuation, or named:
`enter tab space esc backspace delete insert home end pgup pgdn up down
left right f1..f24 apps numlock`.

Aliases for `:k` are `:key` and `:send`.

### Other commands

- `:help`        full key reference (same as `nvdr --show-keys`)
- `:quit`        disconnect and exit
- `:reconnect`   drop and reconnect immediately
- `:sas`         send Ctrl+Alt+Del (works only if the remote NVDA has UI
                 Access — usually no-op)
- `:caps`        swap Insert ↔ CapsLock as the NVDA modifier
- `:say <text>`  push `<text>` into the remote clipboard, then send Ctrl+V
                 (the only way to inject Unicode that doesn't map to keys)

Inside the command prompt: `Enter` runs, `Esc` cancels, `Backspace`
deletes.

## Scripted / one-shot mode (`-k`, `-s`)

For non-interactive use (scripts, AI workflows), `nvdr` can fire a prepared
sequence of keys and typed text, capture any NVDA speech that comes back for
a couple of seconds, print it on stdout, then exit:

```sh
nvdr -c 123456789 -k 'nvda+t; alt+f4; win+d'
nvdr -c 123456789 -s script.txt
```

Separators (`;` or newline) between steps are themselves a 250 ms pause each,
so `a;;;;b` waits a full second between `a` and `b`. Full grammar,
layout/Unicode notes, and examples: see [`scripting.md`](scripting.md).

### Adding a new leader shortcut

The interactive leader table lives in `src/leader.rs` as `SHORTCUTS`. Add
a row like `Shortcut { key: 'r', combo: "win+r", desc: "Run dialog" }`
and it's picked up by both the key handler and `--show-keys` / `:help`.

## Custom leader

```sh
nvdr --leader space     # Ctrl+Space
nvdr --leader k         # Ctrl+K
```

Pick something you don't actually type. Avoid `Ctrl+.` / `Ctrl+,` —
terminals don't encode those into a distinct byte (you'd just send `.` or
`,`). Letters and Space work everywhere.

## What you can't do over a terminal

- Press CapsLock as a key (it's a state toggle, not a transition)
- Press the Windows / Super key by itself
- Distinguish left vs right modifiers
- Press a modifier alone (just Ctrl, just Shift, etc.)
- Use most numpad keys distinctly

For the Windows key, use `:k win+<something>`. For NVDA-modifier behavior,
use the leader.

## Security model

- TLS is mandatory (the relay enforces it).
- The relay's cert is usually self-signed — that's expected. `nvdr` pins
  the SHA-256 fingerprint on first connect (`~/.config/nvdr/known_hosts`)
  and refuses on mismatch.
- A cert change drops you into an interactive prompt with the old and new
  fingerprints. Accept only if you expected the rotation.
- The channel key is a shared secret. Anyone with the key can join — treat
  it like a password.

## Files

- `~/.config/nvdr/known_hosts` — TLS fingerprint cache. One line per host
  (`host:port  <sha256-hex>`). Editable, but you shouldn't need to.

## Caveats

- Sound effects (`wave` / `tone`) are summarized as `[sound: foo.wav]` /
  `[beep 440 Hz]`. They're not played.
- Braille `display` messages are summarized as `[braille N cells]`.
- Insert as a key works only if your terminal sends `\e[2~` for it (most
  do).
- Alt+letter only works if your terminal encodes it as ESC-prefix (almost
  all do; iOS Blink and Termius do too).

## License

Same as the NVDA Remote project.
