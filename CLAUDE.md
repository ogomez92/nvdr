# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`nvdr` is a terminal-based NVDA Remote **master** client in Rust (Tokio + rustls + crossterm). It connects to an NVDA Remote relay over TLS, prints the slave's speech as plain text, and forwards keystrokes back. Single binary crate, no subcrates, no test suite yet.

## Repository layout (monorepo)

This repo holds several independently-built components in different languages that all implement the same wire protocol. `client_spec.md` is the shared contract.

- **`src/` + `Cargo.toml`** — the Rust terminal client. Also exposes `nvdr --ipc`, a line-oriented IPC bridge (`src/ipc.rs`) consumed by the apps below. **This is what the root `Build / run` and `Architecture` sections document.**
- **`addon/`** — the Python NVDA add-on (`globalPlugins/nvdrBridge`), the host/slave side that hooks the keyboard and speech.
- **`ios/`** — the iOS SwiftUI app (xcodegen-generated Xcode project). Bridges an iOS device to a remote NVDA over SSH → `nvdr --ipc`.
- **`mac/`** — the native macOS SwiftUI app. Same role as `ios/`, but with a system-wide low-level keyboard hook (`CGEventTap` + `IOHIDManager`, see `mac/Nvdr/KeyCapture.swift`). Developer ID / non-sandboxed.

`ios/` and `mac/` share ~10 near-identical Swift files (BridgeClient, IPC, RSA*, Settings, SpeechOutput) — kept as deliberate copies, not a shared package; edits to protocol-shaping logic must be mirrored. `mac/Nvdr/VK.swift` mirrors `src/vk.rs`; each Swift tree has its own `AGENTS.md`. Build the apps with `xcodegen generate` then `xcodebuild` inside `ios/` or `mac/`.

## Build / run

```sh
cargo build --release         # binary at target/release/nvdr
cargo run -- --host <h> --port 6837 --channel <key>
cargo run -- --show-keys      # dump the leader / command reference and exit
cargo check                   # fast type-check during edits
cargo clippy --all-targets    # lint
```

MSRV is 1.75+. `rustls` is pinned to the `ring` crypto backend (see `Cargo.toml`) — do not switch to `aws-lc` without reviewing `rustls::crypto::ring::default_provider().install_default()` in `main`.

There are no tests in this repo. If you add one, put unit tests in `#[cfg(test)]` modules inside the file under test (`cargo test` picks them up automatically).

## Authoritative reference: `client_spec.md`

`client_spec.md` is the spec this client implements — it documents the wire protocol (newline-delimited JSON, protocol version 2), connection lifecycle, every message type, and NVDA-specific quirks (scan_code / extended flag per §3.2, unknown-message tolerance per §5.11, `client_left.client` being a dict not an int, etc.). **When touching `protocol.rs`, `transport.rs`, or anything that shapes a wire message, consult `client_spec.md` first — the comments in code already cite sections (`§3.1`, `§5.11`, …).**

## Architecture

Data flows through six modules. Read them in this order the first time:

1. **`protocol.rs`** — `Outbound` (serialize) / `Inbound` (deserialize) enums for every JSON message. `Inbound` is deliberately permissive (`#[serde(other)] Unknown`, all fields `#[serde(default)]`) because the spec says unknown types and fields must be ignored. `speak_text` drops the `[ClassName, attrs]` command arrays inside a `speak.sequence` and keeps only the string entries.

2. **`transport.rs`** — TLS connect with a custom `ServerCertVerifier` (`PinnedVerifier`) that does TOFU pinning against `~/.config/nvdr/known_hosts` (`host:port  <sha256-hex>` per line). Hostname verification is intentionally bypassed — NVDA Remote relays typically use self-signed certs. On mismatch it returns `rustls::Error::General("PIN_MISMATCH host=… stored=… got=… path=…")` — a **machine-readable string** that `main.rs::parse_pin_mismatch` parses to drive the interactive re-pin prompt. If you change that string, update both ends.

3. **`vk.rs`** — Windows VK constants + `scan_for_vk` (plausible US-layout PS/2 scan codes) + `extended_for_vk` (the extended-key flag that matters for NVDA bindings, §3.2). Every `key` message on the wire must carry `vk_code`, `scan_code`, and `extended` — `send_keys` in `main.rs` fills the latter two from here.

4. **`keymap.rs`** — Two entry points that both produce `Vec<Transition>` (a `Transition` is `{vk, pressed}`):
   - `key_event_to_transitions(&KeyEvent)` — crossterm terminal event → VK down/up sequence, synthesizing Shift for shifted punctuation/uppercase. US layout assumed.
   - `parse_combo(spec, nvda_vk)` — parses `:k` command syntax (`ctrl+alt+del`, `win+m`, `nvda+f12`). `nvda_vk` is passed in so the caller controls whether NVDA = Insert or CapsLock.
   Modifiers are emitted in nested order (mods down → base down → base up → mods up, reversed).

5. **`leader.rs`** — 4-state machine (`Normal`, `AfterLeader`, `StickyNvda`, `Command`) that turns crossterm events into `Action`s (`Send`, `SendSas`, `Paste`, `Quit`, `Reconnect`, `Info`, `BeginCommand`, `None`). The leader defaults to Ctrl+G; `is_leader` also accepts the terminal-byte twin for Ctrl+4/5/6/7 (encoded identically to Ctrl+\\/]/^/_). Sticky mode wraps every key in NVDA+. The `:` sub-prompt is an inline line editor — it does **not** switch crossterm out of raw mode, characters buffer into `command_buf`. `HELP` is a `pub const &str` rendered by `--show-keys` and `:help`.

6. **`output.rs`** — renders each `Inbound` to a single terminal line. No ANSI color (screen-reader friendly). `wave` / `tone` / `display` are summarized, not played/rendered. `Ping` and `Cancel` are silent. `Unknown` is silent per §5.11.

7. **`script.rs`** — parser for the one-shot `-k` / `-s` sequence language. Line-oriented (`\n` *and* `;` separate lines); each line is `k <combo>` / `t <text>` / `sleep <ms>` / comment, or is **inferred** (try `parse_combo` first, fall back to literal text). Produces `Vec<script::Step>` where `Step::Type(String)` is executed as clipboard-paste in `main.rs::run_script` (layout-agnostic / Unicode-safe — do **not** re-introduce per-character VK synthesis for text). **Separators are timing:** every `;` / `\n` itself emits a `Step::Sleep(separator_ms)` (default 250 ms), so `a;;;;b` = 4 pauses between steps — this is load-bearing behavior documented in `scripting.md`, don't collapse adjacent separators without updating the doc. Leading/trailing whitespace and separators are trimmed from the source. To extend the grammar, add a new match arm in `parse_line` and a `Step` variant.

8. **`main.rs`** — wires everything. Interactive vs. one-shot dispatch happens in `main()` based on whether `--script`/`--keys` is set. Interactive path: reconnect loop with exponential backoff (500 ms → 30 s cap, reset to 500 ms on a clean connect), session loop (`tokio::select!` over inbound messages and crossterm `EventStream`), held-key bookkeeping (`update_held` / `release_held`) so a mid-chord disconnect doesn't leave a modifier stuck on the slave. `RawGuard` restores terminal state on drop even on panic. One-shot path (`run_script`): single connect, `handshake` (shared with interactive), `wait_for_join` up to 5 s, fire each step — inter-step timing comes *entirely* from `Step::Sleep` emitted by the parser for separators + explicit `sleep`, not from any per-step delay in the runner — then drain inbound for `wait_ms` and print `Speak` text to **stdout** (all other nvdr chatter goes to **stderr** so the stdout channel is clean for piping).

## Non-obvious invariants

- **Every `key` message on the wire includes `scan_code` and `extended`.** The reference slave ignores them, but other implementations may not. Don't drop them in a shortcut.
- **`version_mismatch` is fatal, not a reconnect trigger.** A v3+ server has nothing to say to us; retrying won't help. Other disconnects fall through to the backoff loop.
- **Held-key tracking is per-session.** On any session exit (Dropped, Reconnect, Quit), `release_held` sends key-up for everything still down, in reverse order, before the writer is shut down. Anything bypassing `send_keys` / `update_held` for key transitions risks stuck modifiers.
- **`set_braille_info` must be sent at join** (with `name:"noBraille", numCells:0` if the client doesn't render braille) so the relay doesn't keep sending `display` frames the client will only summarize.
- **Terminal-byte collisions:** Ctrl+4/5/6/7 encode to the same bytes as Ctrl+\\/]/^/_. The leader parser accepts either form; the help text documents this. Ctrl+. and Ctrl+, don't encode distinctly at all — reject them as leader choices if you add validation.
- **`parse_combo` and `key_event_to_transitions` must both be updated** when adding a named key (e.g. a new F-key alias or media key) — they don't share a lookup table.
- **Server hostname in TLS is ignored by the pinning verifier**, but rustls requires *some* `ServerName` at handshake. IP literals fall back to `"localhost"` — don't change this to an error, it's deliberate.
