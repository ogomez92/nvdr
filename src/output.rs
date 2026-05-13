use std::io::{self, Write};

use crate::protocol::{self, Inbound};

/// Render inbound events as plain terminal lines. No ANSI colour to keep it
/// pleasant over screen readers / limited terminals.
pub fn render<W: Write>(mut w: W, msg: &Inbound) -> io::Result<()> {
    match msg {
        Inbound::ChannelJoined { channel, clients, .. } => {
            let channel = channel.as_deref().unwrap_or("?");
            writeln!(
                w,
                "[joined channel {channel} — {} peer(s) already connected]",
                clients.len()
            )?;
        }
        Inbound::Motd { motd, .. } => {
            writeln!(w, "[motd] {motd}")?;
        }
        Inbound::ClientJoined { client, .. } => {
            writeln!(w, "[peer joined: {}]", describe_client(client.as_ref()))?;
        }
        Inbound::ClientLeft { client, .. } => {
            writeln!(w, "[peer left: {}]", describe_client(client.as_ref()))?;
        }
        Inbound::NvdaNotConnected => {
            writeln!(w, "[no NVDA slave in channel — speech won't arrive]")?;
        }
        Inbound::Ping => { /* silent */ }
        Inbound::Error { error } => {
            writeln!(
                w,
                "[server error: {}]",
                error.as_deref().unwrap_or("(unspecified)")
            )?;
        }
        Inbound::VersionMismatch => {
            writeln!(w, "[server rejected protocol version 2]")?;
        }
        Inbound::Speak { sequence, priority } => {
            let text = protocol::speak_text(sequence);
            if text.is_empty() {
                return Ok(());
            }
            let is_now = priority
                .as_ref()
                .and_then(|v| v.as_str())
                .map(|s| s == "now")
                .unwrap_or(false);
            if is_now {
                writeln!(w, "!! {text}")?;
            } else {
                writeln!(w, "{text}")?;
            }
        }
        Inbound::Cancel => { /* nothing meaningful to do in a terminal */ }
        Inbound::PauseSpeech { .. } => { /* slave's local speech state — not ours */ }
        Inbound::Tone { hz, length, .. } => {
            let hz = hz.unwrap_or(0.0);
            let len = length.unwrap_or(0.0);
            writeln!(w, "[beep {hz:.0} Hz for {len:.0} ms]")?;
        }
        Inbound::Wave { file_name } => {
            if let Some(p) = file_name {
                let base = p
                    .rsplit(|c| c == '/' || c == '\\')
                    .next()
                    .unwrap_or(p.as_str());
                writeln!(w, "[sound: {base}]")?;
            }
        }
        Inbound::Display { cells } => {
            writeln!(w, "[braille {} cells]", cells.len())?;
        }
        Inbound::SetClipboardText { text } => {
            let preview: String = text
                .as_deref()
                .unwrap_or("")
                .chars()
                .take(80)
                .collect();
            writeln!(w, "[slave clipboard set: {preview}]")?;
        }
        Inbound::Unknown => { /* silent per §5.11 */ }
    }
    w.flush()
}

fn describe_client(v: Option<&serde_json::Value>) -> String {
    let Some(v) = v else {
        return "(unknown)".into();
    };
    let id = v.get("id").and_then(|x| x.as_u64());
    let ty = v
        .get("connection_type")
        .and_then(|x| x.as_str())
        .unwrap_or("?");
    match id {
        Some(id) => format!("id={id} type={ty}"),
        None => format!("type={ty}"),
    }
}
