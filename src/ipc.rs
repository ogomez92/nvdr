//! Long-running headless mode for driving nvdr from another process — built
//! for the NVDA add-on but usable by any controller. The wire format is plain
//! ASCII, line-oriented, so it's easy to drive from Python / a shell / netcat.
//!
//! # Stdin commands (one per line)
//!
//! - `key <vk> <pressed>` — raw VK transition. `vk` is a decimal u16 Windows
//!   virtual key code; `pressed` is `0` (release) or `1` (press). This is the
//!   path the NVDA add-on uses for passthrough — NVDA already hands us the VK
//!   per keystroke, so there's no point reparsing chord strings.
//! - `combo <spec>` — chord built from `keymap::parse_combo` syntax (e.g.
//!   `ctrl+alt+del`, `nvda+t`). Sends the full down/up sequence. NVDA defaults
//!   to Insert; pass `--nvda-key capslock` to swap.
//! - `type <text>` — paste literal text via the slave's clipboard. Escapes:
//!   `\n`, `\r`, `\\`.
//! - `sas` — send the secure-attention sequence (server-handled Ctrl+Alt+Del).
//! - `release_all` — emit key-up for every VK nvdr still considers held in
//!   this session, in reverse order. The add-on sends this when the user
//!   toggles passthrough off, so stray modifiers don't latch on the slave.
//! - `quit` — clean shutdown.
//!
//! Anything else is logged as `error bad command: …` and ignored. Closing
//! stdin is treated as `quit`. With `--observe`, only `quit` is accepted.
//!
//! # Stdout events (one per line, the channel the controller actually parses)
//!
//! - `speak <text>` — speech text. Embedded `\n` / `\r` are replaced with
//!   spaces so the contract of "one event per line" holds.
//! - `cancel` — slave asked us to interrupt local speech.
//! - `state <name>` — lifecycle: `connecting`, `waiting_for_nvda`, `ready`,
//!   `disconnected`, `quit`.
//! - `error <message>` — non-fatal error worth surfacing to the controller.
//!
//! Everything else (parse warnings, connect attempts, backoff timing) goes to
//! stderr where the add-on tees it into the NVDA log.

use std::collections::HashSet;
use std::io::Write;
use std::sync::Arc;

use anyhow::{anyhow, Result};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;
use tokio::sync::Mutex;

use crate::keymap::{self, Transition};
use crate::protocol::{self, Inbound, Outbound};
use crate::transport;
use crate::vk;

const BACKOFF_MAX_MS: u64 = 30_000;

enum Cmd {
    Key(u16, bool),
    Combo(Vec<Transition>),
    Type(String),
    Sas,
    ReleaseAll,
    Quit,
}

enum SessionOutcome {
    Quit,
    Dropped(String),
    Fatal(anyhow::Error),
}

#[derive(Default)]
struct PeerState {
    slaves: HashSet<u64>,
}

impl PeerState {
    fn apply(&mut self, message: &Inbound) -> Option<&'static str> {
        match message {
            Inbound::ChannelJoined { clients, .. } => {
                self.slaves = clients.iter().filter_map(slave_id).collect();
                Some(self.name())
            }
            Inbound::ClientJoined { client, .. } => {
                let was_ready = !self.slaves.is_empty();
                if let Some(id) = client.as_ref().and_then(slave_id) {
                    self.slaves.insert(id);
                }
                (!was_ready && !self.slaves.is_empty()).then_some("ready")
            }
            Inbound::ClientLeft { client, .. } => {
                let was_ready = !self.slaves.is_empty();
                if let Some(id) = client.as_ref().and_then(client_id) {
                    self.slaves.remove(&id);
                }
                (was_ready && self.slaves.is_empty()).then_some("waiting_for_nvda")
            }
            Inbound::NvdaNotConnected => {
                let changed = !self.slaves.is_empty();
                self.slaves.clear();
                changed.then_some("waiting_for_nvda")
            }
            _ => None,
        }
    }

    fn name(&self) -> &'static str {
        if self.slaves.is_empty() {
            "waiting_for_nvda"
        } else {
            "ready"
        }
    }
}

fn client_id(client: &serde_json::Value) -> Option<u64> {
    client.get("id")?.as_u64()
}

fn slave_id(client: &serde_json::Value) -> Option<u64> {
    (client.get("connection_type")?.as_str()? == "slave")
        .then(|| client_id(client))
        .flatten()
}

fn command_allowed(command: &Cmd, observe: bool) -> bool {
    !observe || matches!(command, Cmd::Quit)
}

pub async fn run(args: crate::Args) -> Result<()> {
    let channel = args
        .channel
        .clone()
        .ok_or_else(|| anyhow!("--ipc requires --channel; refusing to prompt interactively"))?;
    if channel.is_empty() {
        return Err(anyhow!("empty channel"));
    }

    let nvda_vk = vk::VK_INSERT; // `combo nvda+…` will resolve to Insert by default

    let host = args.host.clone();
    let port = args.port;
    let pin_path = args.pin_file.clone().or_else(transport::default_pin_path);

    let mut backoff_ms: u64 = 500;
    loop {
        emit_state("connecting");
        eprintln!("nvdr-ipc: connecting to {host}:{port}…");
        let conn = match transport::connect(
            &host,
            port,
            args.fingerprint.clone(),
            args.insecure,
            pin_path.clone(),
        )
        .await
        {
            Ok(c) => {
                backoff_ms = 500;
                c
            }
            Err(e) => {
                let msg = format!("{e:#}");
                if let Some(m) = crate::parse_pin_mismatch(&msg) {
                    emit_error(&format!(
                        "pin mismatch for {} (stored={} got={}); refusing to auto-accept in ipc mode — pin manually first",
                        m.host, m.stored, m.got
                    ));
                    emit_state("disconnected");
                    return Err(anyhow!("pin mismatch in ipc mode"));
                }
                emit_error(&format!("connect: {msg}"));
                emit_state("disconnected");
                crate::sleep_backoff(&mut backoff_ms, BACKOFF_MAX_MS).await;
                continue;
            }
        };

        match session(conn, &channel, nvda_vk, args.observe).await {
            SessionOutcome::Quit => {
                emit_state("quit");
                return Ok(());
            }
            SessionOutcome::Dropped(msg) => {
                eprintln!("nvdr-ipc: dropped: {msg}");
                emit_state("disconnected");
                crate::sleep_backoff(&mut backoff_ms, BACKOFF_MAX_MS).await;
            }
            SessionOutcome::Fatal(e) => {
                emit_error(&format!("fatal: {e:#}"));
                emit_state("disconnected");
                return Err(e);
            }
        }
    }
}

async fn session(
    conn: transport::TlsConn,
    channel: &str,
    nvda_vk: u16,
    observe: bool,
) -> SessionOutcome {
    let (reader, writer) = tokio::io::split(conn);
    let writer = Arc::new(Mutex::new(writer));

    if let Err(e) = crate::handshake(&writer, channel).await {
        return SessionOutcome::Dropped(format!("handshake: {e}"));
    }

    let (inbound_tx, mut inbound_rx) = mpsc::unbounded_channel::<Inbound>();
    let reader_task = tokio::spawn(crate::read_loop(reader, inbound_tx));

    let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<Cmd>();
    let stdin_task = tokio::spawn(stdin_loop(cmd_tx, nvda_vk));

    let mut held: Vec<u16> = Vec::new();
    let mut peers = PeerState::default();

    let outcome = loop {
        tokio::select! {
            biased;
            msg = inbound_rx.recv() => {
                let Some(msg) = msg else {
                    break SessionOutcome::Dropped("reader closed".into());
                };
                // version_mismatch is fatal per spec §5.x — reconnecting won't help.
                if matches!(msg, Inbound::VersionMismatch) {
                    emit_error("version_mismatch: relay rejected protocol v2");
                    break SessionOutcome::Fatal(anyhow!("version mismatch"));
                }
                if let Some(state) = peers.apply(&msg) {
                    emit_state(state);
                }
                emit_inbound(&msg);
            }
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else {
                    // Stdin closed — controller is gone; shut down cleanly.
                    break SessionOutcome::Quit;
                };
                if !command_allowed(&cmd, observe) {
                    emit_error("observer mode rejects remote-control commands");
                    continue;
                }
                match cmd {
                    Cmd::Key(vk, pressed) => {
                        eprintln!("nvdr-ipc: relay key vk={vk} pressed={pressed}");
                        let ts = [Transition { vk, pressed }];
                        crate::update_held(&mut held, &ts);
                        if let Err(e) = crate::send_keys(&writer, &ts).await {
                            break SessionOutcome::Dropped(format!("send key: {e}"));
                        }
                    }
                    Cmd::Combo(ts) => {
                        crate::update_held(&mut held, &ts);
                        if let Err(e) = crate::send_keys(&writer, &ts).await {
                            break SessionOutcome::Dropped(format!("send combo: {e}"));
                        }
                    }
                    Cmd::Type(text) => {
                        if let Err(e) = crate::send(&writer, &Outbound::SetClipboardText { text: &text }).await {
                            break SessionOutcome::Dropped(format!("set_clipboard_text: {e}"));
                        }
                        let ts = crate::ctrl_v();
                        crate::update_held(&mut held, &ts);
                        if let Err(e) = crate::send_keys(&writer, &ts).await {
                            break SessionOutcome::Dropped(format!("ctrl+v: {e}"));
                        }
                    }
                    Cmd::Sas => {
                        if let Err(e) = crate::send(&writer, &Outbound::SendSas).await {
                            break SessionOutcome::Dropped(format!("sas: {e}"));
                        }
                    }
                    Cmd::ReleaseAll => {
                        let to_release: Vec<u16> = held.iter().rev().copied().collect();
                        let mut drop_err: Option<String> = None;
                        for vk in to_release {
                            let ts = [Transition::up(vk)];
                            crate::update_held(&mut held, &ts);
                            if let Err(e) = crate::send_keys(&writer, &ts).await {
                                drop_err = Some(format!("release_all: {e}"));
                                break;
                            }
                        }
                        if let Some(e) = drop_err {
                            break SessionOutcome::Dropped(e);
                        }
                    }
                    Cmd::Quit => break SessionOutcome::Quit,
                }
            }
        }
    };

    // Best-effort cleanup: drop any modifiers still down on the slave before
    // we let the writer half close, just like the interactive session does.
    crate::release_held(&writer, &held).await;
    {
        let mut w = writer.lock().await;
        let _ = w.shutdown().await;
    }
    reader_task.abort();
    stdin_task.abort();
    outcome
}

async fn stdin_loop(tx: mpsc::UnboundedSender<Cmd>, nvda_vk: u16) {
    let stdin = tokio::io::stdin();
    let mut reader = BufReader::new(stdin);
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line).await {
            Ok(0) => return,
            Ok(_) => {
                let trimmed = line.trim_end_matches(['\r', '\n']);
                if trimmed.is_empty() {
                    continue;
                }
                eprintln!("nvdr-ipc: stdin got: {trimmed}");
                match parse_command(trimmed, nvda_vk) {
                    Ok(cmd) => {
                        let is_quit = matches!(cmd, Cmd::Quit);
                        if tx.send(cmd).is_err() {
                            return;
                        }
                        if is_quit {
                            return;
                        }
                    }
                    Err(e) => {
                        emit_error(&format!("bad command: {e}: {trimmed:?}"));
                    }
                }
            }
            Err(e) => {
                eprintln!("nvdr-ipc: stdin read: {e}");
                return;
            }
        }
    }
}

fn parse_command(line: &str, nvda_vk: u16) -> Result<Cmd, String> {
    let (head, rest) = line
        .split_once(char::is_whitespace)
        .map(|(a, b)| (a, b.trim_start()))
        .unwrap_or((line, ""));
    match head {
        "key" => {
            let mut it = rest.split_whitespace();
            let vk_s = it.next().ok_or_else(|| "key: missing vk".to_string())?;
            let pr_s = it
                .next()
                .ok_or_else(|| "key: missing pressed flag".to_string())?;
            let vk: u16 = vk_s
                .parse()
                .map_err(|_| format!("key: bad vk {vk_s:?}"))?;
            let pressed = match pr_s {
                "0" => false,
                "1" => true,
                _ => return Err(format!("key: pressed must be 0 or 1, got {pr_s:?}")),
            };
            Ok(Cmd::Key(vk, pressed))
        }
        "combo" => {
            if rest.is_empty() {
                return Err("combo: empty spec".into());
            }
            let ts = keymap::parse_combo(rest, nvda_vk)?;
            Ok(Cmd::Combo(ts))
        }
        "type" => Ok(Cmd::Type(unescape(rest))),
        "sas" => Ok(Cmd::Sas),
        "release_all" => Ok(Cmd::ReleaseAll),
        "quit" => Ok(Cmd::Quit),
        _ => Err(format!("unknown command {head:?}")),
    }
}

fn unescape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if c == '\\' {
            match it.next() {
                Some('n') => out.push('\n'),
                Some('r') => out.push('\r'),
                Some('t') => out.push('\t'),
                Some('\\') => out.push('\\'),
                Some(other) => {
                    // Unknown escape: keep both chars so user can see what they wrote.
                    out.push('\\');
                    out.push(other);
                }
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn emit_inbound(msg: &Inbound) {
    match msg {
        Inbound::Speak { sequence, .. } => {
            let text = protocol::speak_text(sequence);
            if !text.is_empty() {
                emit_speak(&text);
            }
        }
        Inbound::Cancel => emit_line("cancel"),
        Inbound::NvdaNotConnected => {}
        Inbound::Error { error } => {
            emit_error(error.as_deref().unwrap_or("(unspecified)"));
        }
        // Everything else is informational — leave the stdout channel clean.
        _ => {}
    }
}

fn emit_speak(text: &str) {
    // Stdout contract is one event per line — collapse any embedded newlines
    // to spaces so a multi-line speech sequence still arrives as a single
    // `speak` event the controller can parse without state.
    let flat: String = text
        .chars()
        .map(|c| if c == '\n' || c == '\r' { ' ' } else { c })
        .collect();
    emit_line(&format!("speak {flat}"));
}

fn emit_state(name: &str) {
    emit_line(&format!("state {name}"));
}

fn emit_error(msg: &str) {
    let flat: String = msg
        .chars()
        .map(|c| if c == '\n' || c == '\r' { ' ' } else { c })
        .collect();
    emit_line(&format!("error {flat}"));
}

fn emit_line(s: &str) {
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(s.as_bytes());
    let _ = out.write_all(b"\n");
    let _ = out.flush();
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn peer_state_follows_slave_membership() {
        let mut peers = PeerState::default();

        assert_eq!(
            peers.apply(&Inbound::ChannelJoined {
                channel: Some("test".into()),
                clients: vec![json!({"id": 1, "connection_type": "master"})],
                origin: Some(2),
            }),
            Some("waiting_for_nvda")
        );
        assert_eq!(
            peers.apply(&Inbound::ClientJoined {
                client: Some(json!({"id": 3, "connection_type": "slave"})),
                origin: Some(3),
            }),
            Some("ready")
        );
        assert_eq!(
            peers.apply(&Inbound::ClientJoined {
                client: Some(json!({"id": 4, "connection_type": "master"})),
                origin: Some(4),
            }),
            None
        );
        assert_eq!(
            peers.apply(&Inbound::ClientLeft {
                client: Some(json!({"id": 3, "connection_type": "slave"})),
                origin: Some(3),
            }),
            Some("waiting_for_nvda")
        );
    }

    #[test]
    fn observer_allows_only_quit() {
        let controls = [
            Cmd::Key(65, true),
            Cmd::Combo(Vec::new()),
            Cmd::Type("text".into()),
            Cmd::Sas,
            Cmd::ReleaseAll,
        ];

        assert!(controls
            .iter()
            .all(|command| !command_allowed(command, true)));
        assert!(command_allowed(&Cmd::Quit, true));
        assert!(command_allowed(&Cmd::Combo(Vec::new()), false));
    }
}
