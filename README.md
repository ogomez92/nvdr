# nvdr

`nvdr` lets you control a remote NVDA screen reader from a machine that isn't
running NVDA — a Linux box over SSH, a Mac, or an iPhone. It speaks the
NVDA Remote relay protocol as the **master** (controller): it hears what the
remote NVDA says and forwards your keystrokes back to it.

> **Disclaimer.** This is a hobby project. I built it for personal use to see
> if the idea would work — nothing more. I'm aware of NVDA's native remote
> access and of the NVDA Remote controller app currently in
> [TestFlight](https://testflight.apple.com/join/edg8YSeU); this is not a
> replacement for either. What `nvdr` adds is (a) an SSH-bridged transport and
> (b) what I believe is better keyboard handling than that TestFlight app in
> some situations. **Contributions are welcome** — especially anything
> around security, but really anything at all.

## What's in this repo

This is a monorepo. Several independently-built components, different
languages, all speaking the same wire protocol (`client_spec.md` is the shared
contract):

| Path             | What it is                                                              |
| ---------------- | ----------------------------------------------------------------------- |
| `src/` + `Cargo.toml` | The Rust terminal client. Also exposes `nvdr --ipc`, a line-oriented IPC bridge used by the apps below. |
| `addon/`         | An NVDA add-on (`nvdrBridge`) — lets a *Windows* NVDA use the SSH bridge.|
| `mac/`           | A native macOS SwiftUI app.                                             |
| `ios/`           | An iOS SwiftUI app.                                                     |

The terminal client connects directly to the relay over TLS. The Mac app, iOS
app, and NVDA add-on all go through the **SSH bridge** instead (see below).

## The SSH bridge — read this first

The Mac app, the iOS app, and the NVDA add-on do **not** open a TLS connection
to the relay themselves. They launch `ssh` and run `nvdr --ipc` on a remote
**bridge box**, and *that* machine dials the NVDA Remote relay:

```
your device (Mac / iOS / Windows+NVDA)
        │  SSH
        ▼
   bridge box  ──  runs `nvdr --ipc`  ──  TLS  ──▶  relay  ──▶  remote NVDA
```

So to use the Mac app, iOS app, or add-on you need a reachable host (Linux,
macOS, or Windows) with the `nvdr` binary built and on its `PATH`, plus
key-based SSH auth set up (no password prompts — the apps can't answer one).

This bridge is useful when you want to **encrypt the whole remote session over
SSH**, or when you simply **can't reach port 6837** (firewalled networks,
captive Wi-Fi, etc.) — your only outbound connection is SSH.

### Caveats of the bridge

- **The Mac and iOS apps use the SSH bridge unconditionally — there is no way
  to turn it off.** They will not connect to a relay directly. If you want a
  direct connection, use the Rust terminal client. A contribution that lets
  the Mac and iOS apps dial the relay directly (no SSH bridge) would be very
  welcome — and I'll likely get around to it myself before long if there's
  demand for it.
- **The bridge only works on the controller (master) side**, not the host
  (slave) side. There is no way to make the *machine being controlled* run
  through this bridge — that machine still needs ordinary NVDA Remote.
- **The bridge forwards keystrokes and speech only.** Other NVDA audio — beeps,
  the forms-mode tone, progress-bar ticks, wave/tone effects — is **not**
  carried across, for now. You get speech text and that's it.
- Connecting NVDA's *native* remote access through this bridge is not
  implemented. If you'd like to add it, contributions are super appreciated.

## The Rust terminal client

A terminal client for the NVDA Remote relay. Designed to run on a VPS over
SSH; works from any terminal on Linux, macOS, Windows, or iOS. This is the
only component that talks to the relay directly (no bridge).

### Build & install

Requires Rust 1.75+.

```sh
cargo build --release        # binary at target/release/nvdr
```

Drop `target/release/nvdr` somewhere on your `$PATH`.

### Quick start

```sh
nvdr                                                  # localhost:6837, prompts for channel
nvdr --host relay.example.com --port 6837 --channel 123456789
nvdr --show-keys                                      # dump the key reference and exit
```

On first connect `nvdr` pins the relay's TLS fingerprint (Trust On First Use)
into `~/.config/nvdr/known_hosts`; later connects verify against it. Relay
certs are usually self-signed — that's expected. A cert change drops you into
an interactive re-pin prompt.

### Using it

Type, and printable characters, arrows, F-keys, Tab/Enter/Esc/Backspace, and
any `Ctrl+letter` are forwarded to the remote NVDA — even `Ctrl+C`. Speech
prints as plain text lines (no ANSI color, screen-reader friendly).

A terminal can't send Insert or the Windows key, so there's a **leader key**
(default `Ctrl+G`, set with `--leader`):

| Shortcut          | Sends   | Meaning           |
| ----------------- | ------- | ----------------- |
| `<leader>` `c`    | Alt+F4  | close window      |
| `<leader>` `w`    | NVDA+T  | read window title |
| `<leader>` `d`    | Win+D   | show desktop      |
| `<leader>` `t`    | Alt+Tab | switch window     |

`<leader>` `<leader>` toggles a sticky NVDA modifier; `<leader>` `:` opens a
command prompt (`:k win+r`, `:caps`, `:say <text>`, `:help`, `:quit`, …).

There's also a one-shot scripting mode (`-k` / `-s`) — see
[`scripting.md`](scripting.md).

### What a terminal can't do

CapsLock as a key, the Windows key alone, left/right modifier distinction, a
modifier pressed alone, most numpad keys. Use `:k win+...` for the Windows key.

## The NVDA add-on (`addon/`)

`nvdrBridge` lets a **Windows** machine running NVDA reach a remote NVDA
*through the SSH bridge* instead of NVDA Remote's normal direct connection —
again, for SSH encryption or when port 6837 is blocked.

- Install: zip the contents of `addon/` (so `manifest.ini` is at the archive
  root), rename to `nvdrBridge.nvda-addon`, install via NVDA's Add-on Store
  ("Install from external source"), restart NVDA.
- Configure under **NVDA → Preferences → Settings → nvdr Bridge** (SSH host /
  user / key, relay host, channel key).
- **`NVDA+F11` toggles key forwarding** between local and remote. While
  forwarding is on, every keystroke (except `NVDA+F11` itself) goes to the
  remote slave and the remote NVDA's speech is spoken on your local synth.

This is the controller side only — see the bridge caveats above. Full setup
and troubleshooting: [`addon/README.md`](addon/README.md).

## The macOS app (`mac/`)

A native SwiftUI app that bridges your Mac to a remote NVDA through the SSH
bridge. It installs a **system-wide low-level keyboard hook**
(`CGEventTap` + `IOHIDManager`).

- **`NVDA+F11` (e.g. `CapsLock+F11`) toggles forwarding** on and off.
- **While forwarding is on, the app eats *all* keystrokes** — including
  `Cmd+Q`, `Cmd+Tab`, and other system shortcuts. They are sent to the remote
  machine, not handled by macOS. Turn forwarding off (`NVDA+F11`) to get your
  keyboard back.
- The app **requires Accessibility and Input Monitoring permissions** to run
  the keyboard hook. It detects when they're missing and shows a banner with
  buttons that jump straight to the relevant System Settings pane.
- It is a Developer ID / **non-sandboxed** app — the keyboard hook can't work
  in the App Store sandbox.

## The iOS app (`ios/`)

A SwiftUI app that bridges an iPhone/iPad to a remote NVDA through the SSH
bridge.

- **`NVDA+F11` toggles forwarding** on and off, same as the Mac app.
- **While forwarding is on, the app captures all hardware-keyboard input** —
  system combos included — and sends it to the remote machine.

## Building the apps

Both Swift apps use xcodegen-generated Xcode projects:

```sh
cd mac        # or: cd ios
xcodegen generate
xcodebuild
```

**These apps will not be published on the App Store** (the Mac one can't be
sandboxed; the iOS one isn't headed there either). Build them yourself from
source.

## Contributing

This started as a personal experiment, so there's plenty of room to improve
it. Some things to look at— **security review and hardening
especially**, but also better protocol coverage (carrying NVDA's non-speech
audio, wiring NVDA's native remote access through the bridge), more keyboard
handling, docs, anything. Open an issue or a PR.

## Files

- `client_spec.md` — the wire protocol this project implements.
- `scripting.md` — the `-k` / `-s` one-shot scripting grammar.
- `~/.config/nvdr/known_hosts` — TLS fingerprint cache for the terminal client.

## License

Same as the NVDA Remote project.
</content>
</invoke>
