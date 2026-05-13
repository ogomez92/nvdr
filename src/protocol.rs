use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const PROTOCOL_VERSION: u32 = 2;

/// Outbound (master → relay → slave) messages.
#[derive(Debug, Serialize)]
#[serde(tag = "type")]
pub enum Outbound<'a> {
    #[serde(rename = "protocol_version")]
    ProtocolVersion { version: u32 },
    #[serde(rename = "join")]
    Join {
        channel: &'a str,
        connection_type: &'a str,
    },
    #[serde(rename = "set_braille_info")]
    SetBrailleInfo {
        name: &'a str,
        #[serde(rename = "numCells")]
        num_cells: u32,
    },
    #[serde(rename = "key")]
    Key {
        vk_code: u16,
        scan_code: u32,
        extended: bool,
        pressed: bool,
    },
    #[serde(rename = "send_SAS")]
    SendSas,
    #[serde(rename = "set_clipboard_text")]
    SetClipboardText { text: &'a str },
}

/// Inbound (slave/relay → master) messages. Kept permissive — unknown fields
/// are ignored per client_spec.md §5.11.
#[allow(dead_code)] // fields retained for debugging / future use
#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
pub enum Inbound {
    #[serde(rename = "channel_joined")]
    ChannelJoined {
        #[serde(default)]
        channel: Option<String>,
        #[serde(default)]
        clients: Vec<Value>,
        #[serde(default)]
        origin: Option<u64>,
    },
    #[serde(rename = "motd")]
    Motd {
        motd: String,
        #[serde(default)]
        force_display: bool,
    },
    #[serde(rename = "client_joined")]
    ClientJoined {
        #[serde(default)]
        client: Option<Value>,
        #[serde(default)]
        origin: Option<u64>,
    },
    #[serde(rename = "client_left")]
    ClientLeft {
        #[serde(default)]
        client: Option<Value>,
        #[serde(default)]
        origin: Option<u64>,
    },
    #[serde(rename = "nvda_not_connected")]
    NvdaNotConnected,
    #[serde(rename = "ping")]
    Ping,
    #[serde(rename = "error")]
    Error {
        #[serde(default)]
        error: Option<String>,
    },
    #[serde(rename = "version_mismatch")]
    VersionMismatch,
    #[serde(rename = "speak")]
    Speak {
        #[serde(default)]
        sequence: Vec<Value>,
        // NVDA's speech.Priority is an IntEnum; depending on slave version it
        // may land on the wire as a string ("now"/"next"/"normal"), an int, or
        // be absent. Accept any JSON value so a bad type doesn't sink the
        // whole frame.
        #[serde(default)]
        priority: Option<Value>,
    },
    #[serde(rename = "cancel")]
    Cancel,
    #[serde(rename = "pause_speech")]
    PauseSpeech {
        #[serde(default)]
        switch: bool,
    },
    #[serde(rename = "tone")]
    Tone {
        #[serde(default)]
        hz: Option<f64>,
        #[serde(default)]
        length: Option<f64>,
        #[serde(default)]
        left: Option<u32>,
        #[serde(default)]
        right: Option<u32>,
    },
    #[serde(rename = "wave")]
    Wave {
        #[serde(rename = "fileName", default)]
        file_name: Option<String>,
    },
    #[serde(rename = "display")]
    Display {
        #[serde(default)]
        cells: Vec<u8>,
    },
    #[serde(rename = "set_clipboard_text")]
    SetClipboardText {
        #[serde(default)]
        text: Option<String>,
    },
    #[serde(other)]
    Unknown,
}

/// Extract the plain-text portion of a `speak.sequence`: concatenate string
/// entries, drop `[ClassName, attrs]` command arrays per §3.1.
pub fn speak_text(sequence: &[Value]) -> String {
    let mut out = String::new();
    for item in sequence {
        if let Some(s) = item.as_str() {
            out.push_str(s);
        }
    }
    out
}
