# nvdrBridge — NVDA add-on

A thin shim that lets your NVDA talk to another NVDA over the NVDA Remote
relay protocol, with the `nvdr` Rust binary acting as an intermediary on a
**remote bridge box that you reach over SSH**.

## Topology

```
your NVDA + add-on  --ssh stdio-->  nvdr --ipc (on bridge)  --TLS-->  relay  --TLS-->  slave NVDA
```

The add-on never opens a TLS socket itself. It launches `ssh` as a subprocess,
SSH runs `nvdr --ipc` on the bridge machine, and the bridge's `nvdr` is what
dials the NVDA Remote relay. Speech events come back up through SSH's stdout
into local speech; keystrokes go down through SSH's stdin to nvdr, then to
the relay, then to the slave.

Why bother with a bridge: persistent pinning/reconnect state on a server that
isn't your workstation, and you don't have to ship `nvdr.exe` to every NVDA
machine — only to the bridge box.

## Prereqs

- **Bridge box**: any reachable host with `nvdr` built and on its `PATH`
  (`cargo build --release` produces `target/release/nvdr`). Linux or macOS or
  Windows — any platform that can run an OpenSSH server and the binary.
- **Your NVDA machine**: OpenSSH client on `PATH` (Windows 10+ ships one).
  Key-based auth set up so SSH doesn't prompt for a password — NVDA can't
  service an interactive prompt. Add the key to `ssh-agent`, or point at it
  with `-i C:\path\to\key` in the Extra SSH args field.

## Install

1. Zip the contents of this `addon/` directory (so `manifest.ini` is at the
   top level of the archive) and rename to `nvdrBridge.nvda-addon`.
2. NVDA → Tools → Add-on Store → Install from external source.
3. Restart NVDA.

## Configure

NVDA → Preferences → Settings → **nvdr Bridge**.

**SSH bridge** group:

- **Bridge host (SSH)** — e.g. `bridge.example.com` or an IP.
- **SSH port** — default 22.
- **SSH user** — what you'd put before the `@` in `user@host`.
- **SSH command** — usually just `ssh`. Set to a full path if it isn't on
  `PATH`, or to `plink.exe` if you prefer PuTTY's client.
- **Extra SSH args** — anything else you want passed to `ssh`. Common use:
  `-i C:\Users\you\.ssh\id_ed25519` for a specific key.
- **Remote nvdr command** — the path / command to invoke on the bridge.
  Default `nvdr` (looks on PATH). Use a full path if not.

**NVDA Remote relay** group:

- **Relay host / port** — the relay nvdr dials out to. Defaults to
  `nvdaremote.com:6837` (the public NVDA Remote relay).
- **Channel key** — shared secret. Whatever the slave-side NVDA Remote uses.
- **Fingerprint** — optional pinned TLS fingerprint. Blank = TOFU on first
  connect (cached on the **bridge box** in `~/.config/nvdr/known_hosts`).
- **Insecure** — skip TLS verification. Testing only.
- **Connection attempts before giving up** — how many consecutive failed
  connects (or lost-session reconnects) to make before nvdr stops retrying and
  waits for you to press NVDA+F11 again. Default 5; set to 0 to retry forever.
  Each failed attempt is spaced by an exponential backoff (0.5s, 1s, 2s … up
  to 30s), and the counter resets to 0 every time a connection succeeds.

Saving the panel restarts the bridge **only if it's currently connected** —
saving never starts a connection by itself (that's what NVDA+F11 is for).

## Use

The bridge does **not** connect when NVDA starts — it connects on demand.

- **NVDA+F11 (first press)** — connect **and** start forwarding. Starts the
  SSH → `nvdr --ipc` session and dials the relay; you'll hear "nvdr
  connecting", then "nvdr connected, sending keys to remote" the moment the
  channel is joined — key forwarding turns on automatically at that point, so
  one press is all it takes. If ssh host or channel aren't set you'll hear
  "nvdr bridge not configured"; if the connection fails you'll hear "nvdr
  couldn't connect" followed by the reason (e.g. an ssh "Permission denied"
  or a relay connect error) — spoken once, not on every background retry.
- **NVDA+F11 (once connected)** — toggle key forwarding off/on.
- While forwarding is on, every keystroke (except NVDA+F11 itself) goes to
  the remote slave, and the remote NVDA's speech is spoken on your local
  synth.
- Toggling forwarding off tells nvdr to release any modifiers it considers
  held on the slave, so nothing latches.

## Troubleshooting

NVDA log: `%tmp%\nvda.log`. Look for `nvdrBridge:` (add-on side) and `nvdr:`
(bridge-side stderr piped through SSH).

- `ssh: cannot find …` — set the **SSH command** field to a full path.
- Add-on logs `pid=…` but nothing else happens — almost always SSH auth
  failing with `BatchMode=yes`. Test by hand:
  `ssh -o BatchMode=yes user@host nvdr --version`. Fix key/agent, then
  restart NVDA (or trigger `Restart the nvdr bridge process` from Input
  gestures).
- `state disconnected` repeating then "nvdr stopped trying to connect" — the
  bridge's nvdr can't reach the relay; it gave up after **Connection attempts
  before giving up** tries. SSH into the bridge yourself and run the same
  `nvdr --ipc …` command to see the real error, then press NVDA+F11 to retry.
- Keys not forwarding — make sure you see `state ready` in the log first.
