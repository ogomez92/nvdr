mod ipc;
mod keymap;
mod leader;
mod output;
mod protocol;
mod script;
mod transport;
mod vk;

use std::io::{self, Write};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use clap::Parser;
use crossterm::event::{Event, EventStream, KeyEventKind};
use crossterm::terminal::{disable_raw_mode, enable_raw_mode};
use futures::StreamExt;
use serde::Serialize;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;
use tokio::sync::Mutex;

use crate::keymap::Transition;
use crate::leader::{Action, Leader};
use crate::protocol::{Inbound, Outbound, PROTOCOL_VERSION};
use crate::vk::{extended_for_vk, scan_for_vk};

#[derive(Parser, Debug)]
#[command(
    version,
    about = "NVDA Remote master client — a terminal/SSH-friendly replacement for the NVDA add-on's master role."
)]
struct Args {
    /// Relay server hostname or IP.
    #[arg(long, short = 'H', default_value = "localhost")]
    host: String,

    /// Relay server port.
    #[arg(long, short = 'p', default_value_t = 6837)]
    port: u16,

    /// Channel key (shared secret). Prompted if omitted.
    #[arg(long, short = 'c')]
    channel: Option<String>,

    /// Pin server cert SHA-256 fingerprint (lowercase hex, no separators).
    /// If omitted, TOFU: first connection pins and caches to
    /// ~/.config/nvdr/known_hosts.
    #[arg(long)]
    fingerprint: Option<String>,

    /// Skip cert verification entirely. Dangerous — only for local testing.
    #[arg(long)]
    insecure: bool,

    /// Leader key: Ctrl+<char>. Accepts a single letter (e.g. `g`), `space`,
    /// or a single punctuation char. Default `g` (BEL / 0x07). Punctuation
    /// like `.` or `,` won't be distinguishable from plain `.`/`,` in most
    /// terminals — prefer a letter.
    #[arg(long, default_value = "g")]
    leader: String,

    /// Override the pin cache path.
    #[arg(long)]
    pin_file: Option<PathBuf>,

    /// Auto-accept a changed server cert (like ssh's `accept-new`, but for
    /// *changes*, not just first-connect). Without this flag, a mismatch
    /// prompts you interactively. You never need to hand-edit the pin file.
    #[arg(long)]
    trust_new_cert: bool,

    /// Print the leader / command reference and exit.
    #[arg(long)]
    show_keys: bool,

    /// Run a one-shot script: send the listed keys/text, capture any NVDA
    /// speech for a bit, print it to stdout, exit. See README for the
    /// grammar. One step per line (newline or `;`), e.g.
    /// `nvda+t; alt+f4; win+m; hello how are you?`
    #[arg(long, short = 's', conflicts_with = "keys")]
    script: Option<PathBuf>,

    /// Same grammar as --script, but the steps come from this string (good
    /// for one-liners; separate steps with `;` or newlines).
    #[arg(long, short = 'k', conflicts_with = "script")]
    keys: Option<String>,

    /// Milliseconds to wait after the last step to collect NVDA speech
    /// before exiting. Only used in --script / --keys mode.
    #[arg(long, default_value_t = 2000)]
    wait_ms: u64,

    /// Milliseconds each separator (`;` or newline) contributes to the
    /// pause between script steps. Repeat separators to lengthen the wait —
    /// `a;;b` = 2× this value, `a;;;;b` = 4×. Only used in --script / --keys
    /// mode.
    #[arg(long, default_value_t = 250)]
    separator_ms: u64,

    /// Long-running headless mode for driving nvdr from another process
    /// (e.g. the NVDA add-on). Reads line-oriented commands from stdin,
    /// emits one-line events to stdout, logs to stderr. See `ipc.rs` for
    /// the grammar.
    #[arg(long, conflicts_with_all = ["script", "keys", "show_keys"])]
    ipc: bool,
}

fn main() -> Result<()> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let args = Args::parse();
    if args.show_keys {
        print!("{}", leader::help());
        return Ok(());
    }
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    if args.ipc {
        rt.block_on(ipc::run(args))
    } else if args.script.is_some() || args.keys.is_some() {
        rt.block_on(run_script(args))
    } else {
        rt.block_on(run(args))
    }
}

async fn run(args: Args) -> Result<()> {
    let channel = match args.channel.clone() {
        Some(c) => c,
        None => prompt_line("channel key: ")?,
    };
    if channel.is_empty() {
        return Err(anyhow!("empty channel"));
    }

    let leader_char = parse_leader(&args.leader)?;

    let host = args.host.clone();

    let mut backoff_ms: u64 = 500;
    const BACKOFF_MAX_MS: u64 = 30_000;

    loop {
        eprintln!("nvdr: connecting to {}:{}…", host, args.port);
        let conn = match transport::connect(
            &host,
            args.port,
            args.fingerprint.clone(),
            args.insecure,
            args.pin_file.clone().or_else(transport::default_pin_path),
        )
        .await
        .context("connecting")
        {
            Ok(c) => {
                backoff_ms = 500;
                c
            }
            Err(e) => {
                let msg = format!("{e:#}");
                if let Some(m) = parse_pin_mismatch(&msg) {
                    if handle_pin_mismatch(&m, args.trust_new_cert)? {
                        // User accepted (or --trust-new-cert set); pin
                        // overwritten. Retry immediately.
                        continue;
                    } else {
                        return Err(anyhow!(
                            "cert fingerprint changed and user declined — refusing to connect"
                        ));
                    }
                }
                if msg.contains("fingerprint") {
                    // Explicit --fingerprint mismatch: fatal (user supplied it).
                    eprintln!("nvdr: {msg}");
                    return Err(e);
                }
                eprintln!("nvdr: connect failed: {msg}");
                sleep_backoff(&mut backoff_ms, BACKOFF_MAX_MS).await;
                continue;
            }
        };

        match session(conn, &channel, leader_char).await {
            SessionOutcome::Reconnect => {
                eprintln!("nvdr: reconnecting…");
                backoff_ms = 500;
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
            SessionOutcome::Dropped(msg) => {
                eprintln!("nvdr: connection dropped ({msg}); reconnecting…");
                sleep_backoff(&mut backoff_ms, BACKOFF_MAX_MS).await;
            }
            SessionOutcome::Quit => {
                eprintln!("nvdr: bye.");
                return Ok(());
            }
            SessionOutcome::Fatal(e) => {
                eprintln!("nvdr: {e:#}");
                return Err(e);
            }
        }
    }
}

pub(crate) async fn sleep_backoff(backoff_ms: &mut u64, cap: u64) {
    let d = Duration::from_millis(*backoff_ms);
    eprintln!("nvdr: waiting {:.1}s before retry", d.as_secs_f32());
    tokio::time::sleep(d).await;
    *backoff_ms = (*backoff_ms * 2).min(cap);
}

enum SessionOutcome {
    Quit,
    Reconnect,
    /// Network drop — retry with backoff.
    Dropped(String),
    /// Unrecoverable — abort.
    Fatal(anyhow::Error),
}

async fn session(conn: transport::TlsConn, channel: &str, leader_char: char) -> SessionOutcome {
    let (reader, writer) = tokio::io::split(conn);
    let writer = Arc::new(Mutex::new(writer));

    if let Err(e) = handshake(&writer, channel).await {
        return SessionOutcome::Dropped(format!("handshake: {e}"));
    }

    let (inbound_tx, mut inbound_rx) = mpsc::unbounded_channel::<Inbound>();
    let reader_task = tokio::spawn(read_loop(reader, inbound_tx));

    if let Err(e) = enable_raw_mode() {
        return SessionOutcome::Fatal(anyhow!("enable_raw_mode: {e}"));
    }
    let _raw_guard = RawGuard;

    let leader_label = if leader_char == ' ' {
        "Space".to_string()
    } else {
        leader_char.to_ascii_uppercase().to_string()
    };
    eprintln!(
        "nvdr: raw mode on. Leader is Ctrl+{leader_label} — press it then a letter to send NVDA+<letter>. Type Ctrl+{leader_label} then `:help` for commands.\r",
    );
    let _ = std::io::stderr().flush();

    let mut leader = Leader::new(leader_char);
    let mut held: Vec<u16> = Vec::new();
    let mut events = EventStream::new();
    let outcome: SessionOutcome = loop {
        tokio::select! {
            biased;
            msg = inbound_rx.recv() => {
                let Some(msg) = msg else {
                    break SessionOutcome::Dropped("reader closed".into());
                };
                // version_mismatch is fatal per spec — a newer server with
                // protocol v3+ won't speak to us and we can't help by
                // reconnecting.
                if matches!(msg, Inbound::VersionMismatch) {
                    let mut buf = Vec::new();
                    let _ = output::render(&mut buf, &msg);
                    write_raw_buf(&buf);
                    break SessionOutcome::Fatal(anyhow!(
                        "relay rejected protocol version 2"
                    ));
                }
                let mut buf = Vec::new();
                if let Err(e) = output::render(&mut buf, &msg) {
                    break SessionOutcome::Fatal(e.into());
                }
                write_raw_buf(&buf);
            }
            ev = events.next() => {
                let Some(ev) = ev else { break SessionOutcome::Fatal(anyhow!("stdin closed")) };
                let ev = match ev {
                    Ok(e) => e,
                    Err(e) => break SessionOutcome::Fatal(anyhow!("terminal read: {e}")),
                };
                let Event::Key(key) = ev else { continue };
                if matches!(key.kind, KeyEventKind::Release) { continue }
                let action = leader.handle(key);
                match action {
                    Action::None => {}
                    Action::Info(s) => {
                        let mut stdout = std::io::stdout().lock();
                        let _ = writeln_raw(&mut stdout, &s);
                    }
                    Action::BeginCommand => {
                        let mut stdout = std::io::stdout().lock();
                        let _ = stdout.write_all(b":");
                        let _ = stdout.flush();
                    }
                    Action::Send(ts) => {
                        update_held(&mut held, &ts);
                        if let Err(e) = send_keys(&writer, &ts).await {
                            break SessionOutcome::Dropped(format!("{e}"));
                        }
                    }
                    Action::SendSas => {
                        if let Err(e) = send(&writer, &Outbound::SendSas).await {
                            break SessionOutcome::Dropped(format!("{e}"));
                        }
                    }
                    Action::Paste(text) => {
                        if let Err(e) = send(&writer, &Outbound::SetClipboardText { text: &text }).await {
                            break SessionOutcome::Dropped(format!("{e}"));
                        }
                        let ts = ctrl_v();
                        update_held(&mut held, &ts);
                        if let Err(e) = send_keys(&writer, &ts).await {
                            break SessionOutcome::Dropped(format!("{e}"));
                        }
                    }
                    Action::Quit => break SessionOutcome::Quit,
                    Action::Reconnect => break SessionOutcome::Reconnect,
                }
            }
        }
    };

    release_held(&writer, &held).await;
    {
        let mut w = writer.lock().await;
        let _ = w.shutdown().await;
    }
    reader_task.abort();
    outcome
}

struct RawGuard;
impl Drop for RawGuard {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = std::io::stdout().write_all(b"\r\n");
        let _ = std::io::stdout().flush();
    }
}

fn writeln_raw<W: Write>(w: &mut W, line: &str) -> io::Result<()> {
    w.write_all(line.as_bytes())?;
    w.write_all(b"\r\n")?;
    w.flush()
}

fn write_raw_buf(buf: &[u8]) {
    let mut stdout = std::io::stdout().lock();
    for line in buf.split_inclusive(|b| *b == b'\n') {
        if let Some((body, _)) = line.split_last().filter(|(last, _)| **last == b'\n').map(|(last, rest)| (rest, last)) {
            let _ = stdout.write_all(body);
            let _ = stdout.write_all(b"\r\n");
        } else {
            let _ = stdout.write_all(line);
        }
    }
    let _ = stdout.flush();
}

pub(crate) async fn handshake(
    writer: &Arc<Mutex<tokio::io::WriteHalf<transport::TlsConn>>>,
    channel: &str,
) -> Result<()> {
    send(
        writer,
        &Outbound::ProtocolVersion {
            version: PROTOCOL_VERSION,
        },
    )
    .await?;
    send(
        writer,
        &Outbound::Join {
            channel,
            connection_type: "master",
        },
    )
    .await?;
    send(
        writer,
        &Outbound::SetBrailleInfo {
            name: "noBraille",
            num_cells: 0,
        },
    )
    .await?;
    Ok(())
}

pub(crate) async fn send<T: Serialize>(
    writer: &Arc<Mutex<tokio::io::WriteHalf<transport::TlsConn>>>,
    msg: &T,
) -> Result<()> {
    let mut bytes = serde_json::to_vec(msg)?;
    bytes.push(b'\n');
    let mut w = writer.lock().await;
    w.write_all(&bytes).await?;
    w.flush().await?;
    Ok(())
}

pub(crate) async fn send_keys(
    writer: &Arc<Mutex<tokio::io::WriteHalf<transport::TlsConn>>>,
    ts: &[Transition],
) -> Result<()> {
    for t in ts {
        let msg = Outbound::Key {
            vk_code: t.vk,
            scan_code: scan_for_vk(t.vk),
            extended: extended_for_vk(t.vk),
            pressed: t.pressed,
        };
        send(writer, &msg).await?;
    }
    Ok(())
}

pub(crate) fn ctrl_v() -> Vec<Transition> {
    vec![
        Transition::down(vk::VK_CONTROL),
        Transition::down(0x56),
        Transition::up(0x56),
        Transition::up(vk::VK_CONTROL),
    ]
}

pub(crate) fn update_held(held: &mut Vec<u16>, ts: &[Transition]) {
    for t in ts {
        if t.pressed {
            if !held.contains(&t.vk) {
                held.push(t.vk);
            }
        } else {
            held.retain(|vk| *vk != t.vk);
        }
    }
}

pub(crate) async fn release_held(
    writer: &Arc<Mutex<tokio::io::WriteHalf<transport::TlsConn>>>,
    held: &[u16],
) {
    for vk in held.iter().rev() {
        let _ = send(
            writer,
            &Outbound::Key {
                vk_code: *vk,
                scan_code: scan_for_vk(*vk),
                extended: extended_for_vk(*vk),
                pressed: false,
            },
        )
        .await;
    }
}

pub(crate) async fn read_loop(
    reader: tokio::io::ReadHalf<transport::TlsConn>,
    out: mpsc::UnboundedSender<Inbound>,
) {
    let mut reader = BufReader::new(reader);
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line).await {
            Ok(0) => return,
            Ok(_) => {
                let trimmed = line.trim_end_matches(['\r', '\n']);
                match serde_json::from_str::<Inbound>(trimmed) {
                    Ok(msg) => {
                        if out.send(msg).is_err() {
                            return;
                        }
                    }
                    Err(e) => {
                        let preview: String = trimmed.chars().take(200).collect();
                        eprintln!("nvdr: [skipped unparseable frame] {e}: {preview}\r");
                    }
                }
            }
            Err(_) => return,
        }
    }
}

fn parse_leader(s: &str) -> Result<char> {
    let t = s.trim();
    if t.eq_ignore_ascii_case("space") || t == " " {
        return Ok(' ');
    }
    if t.chars().count() == 1 {
        return Ok(t.chars().next().unwrap().to_ascii_lowercase());
    }
    Err(anyhow!(
        "--leader must be a single character, or `space`; got {s:?}"
    ))
}

fn prompt_line(prompt: &str) -> Result<String> {
    let mut out = std::io::stderr();
    out.write_all(prompt.as_bytes())?;
    out.flush()?;
    let mut line = String::new();
    std::io::stdin().read_line(&mut line)?;
    Ok(line.trim().to_string())
}

pub(crate) struct PinMismatch {
    pub host: String,
    pub stored: String,
    pub got: String,
    pub path: PathBuf,
}

/// Parse the machine-readable error string emitted by our TLS verifier on a
/// TOFU fingerprint mismatch. Returns None if the error isn't a pin mismatch.
pub(crate) fn parse_pin_mismatch(msg: &str) -> Option<PinMismatch> {
    let idx = msg.find("PIN_MISMATCH ")?;
    let tail = &msg[idx + "PIN_MISMATCH ".len()..];
    let mut host = None;
    let mut stored = None;
    let mut got = None;
    let mut path = None;
    for part in tail.split(' ') {
        if let Some(v) = part.strip_prefix("host=") {
            host = Some(v.to_string());
        } else if let Some(v) = part.strip_prefix("stored=") {
            stored = Some(v.to_string());
        } else if let Some(v) = part.strip_prefix("got=") {
            got = Some(v.to_string());
        } else if let Some(v) = part.strip_prefix("path=") {
            path = Some(PathBuf::from(v));
        }
    }
    Some(PinMismatch {
        host: host?,
        stored: stored?,
        got: got?,
        path: path?,
    })
}

/// Show the user what changed, prompt for yes/no, and overwrite the pin if
/// they accept. Returns Ok(true) if the user (or `--trust-new-cert`) accepted
/// and the pin was updated; Ok(false) if they declined.
fn handle_pin_mismatch(m: &PinMismatch, auto_accept: bool) -> Result<bool> {
    eprintln!();
    eprintln!("⚠️  SERVER CERTIFICATE CHANGED for {}", m.host);
    eprintln!("   stored fingerprint: {}", m.stored);
    eprintln!("   new fingerprint:    {}", m.got);
    eprintln!("   pin file:           {}", m.path.display());
    eprintln!();
    eprintln!("If the relay operator rotated the cert, this is expected.");
    eprintln!("If you did not expect a change, this could be a MITM — abort.");

    let accept = if auto_accept {
        eprintln!("[auto-accepting because --trust-new-cert]");
        true
    } else {
        let ans = prompt_line("trust the new certificate? [y/N]: ")?;
        matches!(ans.as_str(), "y" | "Y" | "yes" | "YES")
    };
    if accept {
        transport::store_pin(&m.path, &m.host, &m.got)
            .with_context(|| format!("updating pin at {}", m.path.display()))?;
        eprintln!("nvdr: pin updated.");
    }
    Ok(accept)
}

/// One-shot mode: load `--script` / `--keys`, connect, fire the sequence,
/// print any NVDA speech that comes back on stdout, exit. No raw mode, no
/// reconnect loop — failures return a nonzero exit.
async fn run_script(args: Args) -> Result<()> {
    let source = if let Some(path) = &args.script {
        std::fs::read_to_string(path)
            .with_context(|| format!("reading script {}", path.display()))?
    } else if let Some(s) = &args.keys {
        s.clone()
    } else {
        unreachable!("caller guards on script.is_some() || keys.is_some()")
    };

    let channel = match args.channel.clone() {
        Some(c) => c,
        None => prompt_line("channel key: ")?,
    };
    if channel.is_empty() {
        return Err(anyhow!("empty channel"));
    }

    let steps = script::parse(&source, vk::VK_INSERT, args.separator_ms)
        .map_err(|e| anyhow!("script parse: {e}"))?;
    if steps.is_empty() {
        return Err(anyhow!("script contained no steps"));
    }

    eprintln!("nvdr: connecting to {}:{}…", args.host, args.port);
    let conn = transport::connect(
        &args.host,
        args.port,
        args.fingerprint.clone(),
        args.insecure,
        args.pin_file.clone().or_else(transport::default_pin_path),
    )
    .await
    .context("connecting")?;

    let (reader, writer) = tokio::io::split(conn);
    let writer = Arc::new(Mutex::new(writer));

    handshake(&writer, &channel).await.context("handshake")?;

    let (inbound_tx, mut inbound_rx) = mpsc::unbounded_channel::<Inbound>();
    let reader_task = tokio::spawn(read_loop(reader, inbound_tx));

    wait_for_join(&mut inbound_rx, Duration::from_secs(5)).await?;

    // Inter-step timing is entirely driven by separators and explicit
    // `sleep <ms>`, which the parser has already expanded into Step::Sleep.
    let mut held: Vec<u16> = Vec::new();
    for step in &steps {
        match step {
            script::Step::Key(ts) => {
                update_held(&mut held, ts);
                if let Err(e) = send_keys(&writer, ts).await {
                    release_held(&writer, &held).await;
                    return Err(anyhow!("send: {e}"));
                }
            }
            script::Step::Type(text) => {
                // Clipboard + Ctrl+V — layout-agnostic, Unicode-safe. Mirrors
                // what the interactive `:say` command does.
                if let Err(e) = send(&writer, &Outbound::SetClipboardText { text }).await {
                    release_held(&writer, &held).await;
                    return Err(anyhow!("set_clipboard_text: {e}"));
                }
                let ts = ctrl_v();
                update_held(&mut held, &ts);
                if let Err(e) = send_keys(&writer, &ts).await {
                    release_held(&writer, &held).await;
                    return Err(anyhow!("send Ctrl+V: {e}"));
                }
            }
            script::Step::Sleep(d) => {
                tokio::time::sleep(*d).await;
            }
        }
    }
    release_held(&writer, &held).await;

    // Drain speech for wait_ms after the last step. Speech text → stdout;
    // other frames are silently ignored (errors and nvda_not_connected go to
    // stderr so they don't contaminate the script's output).
    let deadline = tokio::time::Instant::now() + Duration::from_millis(args.wait_ms);
    loop {
        let now = tokio::time::Instant::now();
        let Some(remaining) = deadline.checked_duration_since(now) else {
            break;
        };
        tokio::select! {
            msg = inbound_rx.recv() => {
                let Some(msg) = msg else { break };
                match msg {
                    Inbound::Speak { sequence, .. } => {
                        let text = protocol::speak_text(&sequence);
                        if !text.is_empty() {
                            println!("{text}");
                        }
                    }
                    Inbound::NvdaNotConnected => {
                        eprintln!("nvdr: warning: no NVDA slave connected to the channel");
                    }
                    Inbound::Error { error } => {
                        eprintln!(
                            "nvdr: server error: {}",
                            error.as_deref().unwrap_or("(unspecified)")
                        );
                    }
                    _ => {}
                }
            }
            _ = tokio::time::sleep(remaining) => break,
        }
    }

    {
        let mut w = writer.lock().await;
        let _ = w.shutdown().await;
    }
    reader_task.abort();
    Ok(())
}

pub(crate) async fn wait_for_join(
    rx: &mut mpsc::UnboundedReceiver<Inbound>,
    timeout: Duration,
) -> Result<()> {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let now = tokio::time::Instant::now();
        let Some(remaining) = deadline.checked_duration_since(now) else {
            return Err(anyhow!("timed out waiting for channel_joined"));
        };
        tokio::select! {
            msg = rx.recv() => match msg {
                Some(Inbound::ChannelJoined { .. }) => return Ok(()),
                Some(Inbound::VersionMismatch) => {
                    return Err(anyhow!("relay rejected protocol version 2"));
                }
                Some(_) => continue,
                None => return Err(anyhow!("connection closed before channel_joined")),
            },
            _ = tokio::time::sleep(remaining) => {
                return Err(anyhow!("timed out waiting for channel_joined"));
            }
        }
    }
}
