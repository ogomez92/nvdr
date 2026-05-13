use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::keymap::{self, Transition};
use crate::vk::*;

/// Commands the input loop should perform as a result of a keystroke.
#[derive(Debug)]
pub enum Action {
    /// No-op (e.g. entering/leaving leader mode).
    None,
    /// Send these transitions to the slave (with modifier bracketing already
    /// applied).
    Send(Vec<Transition>),
    /// Send Ctrl+Alt+Del.
    SendSas,
    /// Push text to peer clipboard and synthesize Ctrl+V.
    Paste(String),
    /// User requested exit.
    Quit,
    /// User requested reconnect.
    Reconnect,
    /// Print an informational line above the prompt.
    Info(String),
    /// Ask the reader to switch to line-mode and read a command line, then
    /// return it via `command_line`.
    BeginCommand,
}

#[derive(Debug, PartialEq, Eq)]
enum Mode {
    Normal,
    /// Just saw the leader; next key is interpreted as NVDA+<key>.
    AfterLeader,
    /// Sticky NVDA modifier — every subsequent key is NVDA+<key> until the
    /// user presses leader-leader again.
    StickyNvda,
    /// Reading `:command` — characters are buffered into `command_buf`.
    Command,
}

pub struct Leader {
    mode: Mode,
    pub command_buf: String,
    /// VK code used as the NVDA modifier. Defaults to Insert; `:caps` swaps
    /// to CapsLock for users who configured NVDA that way.
    nvda_vk: u16,
    /// The key that opens leader mode. We parse it once at startup.
    leader_ctrl_char: char,
}

#[allow(dead_code)] // some accessors reserved for future integrations
impl Leader {
    pub fn new(leader_ctrl_char: char) -> Self {
        Self {
            mode: Mode::Normal,
            command_buf: String::new(),
            nvda_vk: VK_INSERT,
            leader_ctrl_char,
        }
    }

    pub fn nvda_vk(&self) -> u16 {
        self.nvda_vk
    }

    pub fn in_command_mode(&self) -> bool {
        matches!(self.mode, Mode::Command)
    }

    pub fn sticky(&self) -> bool {
        matches!(self.mode, Mode::StickyNvda)
    }

    /// Detect leader: Ctrl+<char> where char is the configured leader char.
    ///
    /// Terminals encode some Ctrl combinations onto the same byte:
    /// Ctrl+4 ≡ Ctrl+\ (0x1C), Ctrl+5 ≡ Ctrl+] (0x1D),
    /// Ctrl+6 ≡ Ctrl+^ (0x1E), Ctrl+7 ≡ Ctrl+_ (0x1F). Crossterm reports
    /// the digit form. We accept either form.
    fn is_leader(&self, ev: &KeyEvent) -> bool {
        if !ev.modifiers.contains(KeyModifiers::CONTROL) {
            return false;
        }
        let KeyCode::Char(c) = ev.code else {
            return false;
        };
        if c.eq_ignore_ascii_case(&self.leader_ctrl_char) {
            return true;
        }
        leader_equivalent(self.leader_ctrl_char)
            .map(|alt| c.eq_ignore_ascii_case(&alt))
            .unwrap_or(false)
    }

    pub fn handle(&mut self, ev: KeyEvent) -> Action {
        match self.mode {
            Mode::Command => self.handle_command_char(ev),
            Mode::Normal => {
                if self.is_leader(&ev) {
                    self.mode = Mode::AfterLeader;
                    return Action::Info("-- leader --".into());
                }
                if matches!(self.mode, Mode::StickyNvda) {
                    return self.wrap_with_nvda(ev);
                }
                self.emit_plain(ev)
            }
            Mode::AfterLeader => {
                // Double leader → toggle sticky
                if self.is_leader(&ev) {
                    self.mode = Mode::StickyNvda;
                    return Action::Info("-- sticky NVDA modifier on --".into());
                }
                // `:` → start command prompt
                if let KeyCode::Char(':') = ev.code {
                    self.mode = Mode::Command;
                    self.command_buf.clear();
                    return Action::BeginCommand;
                }
                self.mode = Mode::Normal;
                if let KeyCode::Char(c) = ev.code {
                    let lc = c.to_ascii_lowercase();
                    if let Some(sc) = SHORTCUTS.iter().find(|s| s.key == lc) {
                        return match keymap::parse_combo(sc.combo, self.nvda_vk) {
                            Ok(ts) => Action::Send(ts),
                            Err(e) => Action::Info(format!(
                                "-- bad built-in shortcut '{}' → {}: {e} --",
                                sc.key, sc.combo
                            )),
                        };
                    }
                    return Action::Info(format!(
                        "-- no shortcut for '{c}' (try <leader> :help) --"
                    ));
                }
                Action::Info("-- no shortcut for that key (try <leader> :help) --".into())
            }
            Mode::StickyNvda => {
                if self.is_leader(&ev) {
                    self.mode = Mode::Normal;
                    return Action::Info("-- sticky NVDA modifier off --".into());
                }
                self.wrap_with_nvda(ev)
            }
        }
    }

    fn emit_plain(&self, ev: KeyEvent) -> Action {
        match keymap::key_event_to_transitions(&ev) {
            Some(ts) => Action::Send(ts),
            None => Action::None,
        }
    }

    fn wrap_with_nvda(&self, ev: KeyEvent) -> Action {
        // Build inner transitions first (the key with its own modifiers) and
        // wrap them in NVDA-modifier down/up.
        let Some(mut inner) = keymap::key_event_to_transitions(&ev) else {
            return Action::None;
        };
        let mut all = Vec::with_capacity(inner.len() + 2);
        all.push(Transition::down(self.nvda_vk));
        all.append(&mut inner);
        all.push(Transition::up(self.nvda_vk));
        Action::Send(all)
    }

    fn handle_command_char(&mut self, ev: KeyEvent) -> Action {
        // Treat Ctrl+J / Ctrl+M as Enter; Ctrl+H / Ctrl+? as Backspace.
        let ctrl = ev.modifiers.contains(KeyModifiers::CONTROL);
        match ev.code {
            KeyCode::Enter => return self.finish_command(),
            KeyCode::Esc => {
                self.command_buf.clear();
                self.mode = Mode::Normal;
                return Action::Info("-- command cancelled --".into());
            }
            KeyCode::Backspace => {
                self.command_buf.pop();
                return Action::Info(format!(":{}", self.command_buf));
            }
            KeyCode::Char(c) => {
                if ctrl {
                    match c {
                        'j' | 'm' => return self.finish_command(),
                        'h' => {
                            self.command_buf.pop();
                            return Action::Info(format!(":{}", self.command_buf));
                        }
                        'c' => {
                            self.command_buf.clear();
                            self.mode = Mode::Normal;
                            return Action::Info("-- command cancelled --".into());
                        }
                        _ => return Action::None,
                    }
                }
                self.command_buf.push(c);
                return Action::Info(format!(":{}", self.command_buf));
            }
            _ => {}
        }
        Action::None
    }

    fn finish_command(&mut self) -> Action {
        let line = std::mem::take(&mut self.command_buf);
        self.mode = Mode::Normal;
        self.run_command(line.trim())
    }

    fn run_command(&mut self, line: &str) -> Action {
        let mut parts = line.splitn(2, char::is_whitespace);
        let cmd = parts.next().unwrap_or("");
        let arg = parts.next().unwrap_or("").to_string();
        match cmd {
            "" => Action::None,
            "q" | "quit" | "exit" => Action::Quit,
            "sas" => Action::SendSas,
            "caps" => {
                self.nvda_vk = if self.nvda_vk == VK_INSERT {
                    VK_CAPITAL
                } else {
                    VK_INSERT
                };
                Action::Info(format!(
                    "-- NVDA modifier is now {} --",
                    keymap::vk_name(self.nvda_vk)
                ))
            }
            "reconnect" => Action::Reconnect,
            "say" | "paste" => {
                if arg.is_empty() {
                    Action::Info("usage: :say <text>".into())
                } else {
                    Action::Paste(arg)
                }
            }
            "k" | "key" | "send" => {
                if arg.is_empty() {
                    Action::Info(
                        "usage: :k <combo>   e.g. :k win+m, :k ctrl+alt+del, :k alt+f4"
                            .into(),
                    )
                } else {
                    match keymap::parse_combo(&arg, self.nvda_vk) {
                        Ok(ts) => Action::Send(ts),
                        Err(e) => Action::Info(format!("-- bad combo: {e} --")),
                    }
                }
            }
            "help" | "?" => Action::Info(help().trim_start().to_string()),
            other => Action::Info(format!("-- unknown command: {other} (try :help) --")),
        }
    }
}

/// Map a leader char to its terminal-byte twin (so we recognise either form).
fn leader_equivalent(c: char) -> Option<char> {
    match c {
        '\\' => Some('4'),
        ']' => Some('5'),
        '^' => Some('6'),
        '_' => Some('7'),
        '4' => Some('\\'),
        '5' => Some(']'),
        '6' => Some('^'),
        '7' => Some('_'),
        _ => None,
    }
}

/// A built-in keyboard shortcut accessible via `<leader> <key>`. `combo` is a
/// string parsed by `keymap::parse_combo`, so it can use any syntax `:k`
/// accepts (`alt+f4`, `nvda+t`, `win+d`, etc.). To add a shortcut: append a
/// row here — it shows up in `--show-keys` / `:help` automatically.
pub struct Shortcut {
    pub key: char,
    pub combo: &'static str,
    pub desc: &'static str,
}

pub const SHORTCUTS: &[Shortcut] = &[
    Shortcut { key: 'c', combo: "alt+f4",  desc: "close window (Alt+F4)" },
    Shortcut { key: 'w', combo: "nvda+t",  desc: "read window title (NVDA+T)" },
    Shortcut { key: 'd', combo: "win+d",   desc: "show desktop (Win+D)" },
    Shortcut { key: 't', combo: "alt+tab", desc: "switch window (Alt+Tab)" },
];

pub fn help() -> String {
    let mut sc_lines = String::new();
    for sc in SHORTCUTS {
        sc_lines.push_str(&format!(
            "  <leader> {}          {}\n",
            sc.key, sc.desc
        ));
    }
    format!(r#"
nvdr key reference
------------------

LEADER (default Ctrl+G — configurable via --leader)
  <leader> <letter>    run a built-in shortcut (see LEADER SHORTCUTS below)
  <leader> <leader>    toggle sticky NVDA modifier (every key wraps in NVDA+
                       until toggled off)
  <leader> :           open command prompt (see COMMANDS)

LEADER SHORTCUTS
{sc_lines}  Add more by editing the SHORTCUTS table in src/leader.rs.

PLAIN TYPING
  Letters, digits, punctuation, space, Tab, Enter, Backspace, Esc → forwarded
  Shift+letter → uppercase (as your terminal reports it)
  Alt+letter   → forwarded (on terminals that encode Alt as ESC-prefix)

CONTROL KEYS — all sent to the slave, NOT to your local shell
  Ctrl+A..Z            forwarded verbatim (Ctrl+letter)
  Ctrl+C               forwarded (NOT treated as SIGINT locally)
  Ctrl+Z               forwarded (NOT suspended locally)
  Ctrl+S / Ctrl+Q      forwarded (flow-control disabled)
  Ctrl+D               forwarded
  Ctrl+\  / Ctrl+4     forwarded as Ctrl+\   (indistinguishable bytes)
  Ctrl+]  / Ctrl+5     forwarded as Ctrl+]
  Ctrl+^  / Ctrl+6     forwarded as Ctrl+^
  Ctrl+_  / Ctrl+7     forwarded as Ctrl+_
  Ctrl+Space           NUL (0x00); also a valid leader if configured

NAVIGATION & EDITING (captured from terminal escape sequences)
  Arrow keys ← → ↑ ↓   sent as VK_LEFT / VK_RIGHT / VK_UP / VK_DOWN
  Home / End           VK_HOME / VK_END
  PageUp / PageDown    VK_PRIOR / VK_NEXT
  Delete               VK_DELETE (extended)
  Insert               VK_INSERT — if your terminal sends \e[2~ (most do)
  F1 – F12             sent as VK_F1..F12 (if terminal encodes them)
  Shift+Tab            BackTab → Shift+VK_TAB

KEYS YOU CAN'T TYPE OVER A TERMINAL
  NVDA modifier (Insert or CapsLock)  → use a leader shortcut, sticky via
                                         <leader> <leader>, or :k nvda+<key>
  Windows / Super key                 → use a leader shortcut or :k win+<key>
  CapsLock alone                      → no way to send (can't toggle lock)
  Left vs right modifier distinction  → not reachable
  Standalone modifier press (Ctrl by itself, etc.) → not reachable
  Numpad keys                         → most terminals don't distinguish

COMMANDS  (type <leader> then `:` to open the prompt)
  :help                show this reference
  :quit                disconnect and exit nvdr
  :reconnect           drop the current connection and reconnect now
  :sas                 send Ctrl+Alt+Del (requires slave UI Access)
  :caps                swap Insert ↔ CapsLock as the NVDA modifier
  :say <text>          paste <text> on the slave (clipboard + synth Ctrl+V)
  :k <combo>           send arbitrary key combo (alias :key, :send)
                       modifiers: ctrl alt shift win nvda caps
                       base:      a-z 0-9 punctuation, or named:
                                  enter tab space esc backspace delete
                                  insert home end pgup pgdn up down left
                                  right f1..f24 apps numlock
                       examples:  :k win+m         (minimize all)
                                  :k win+d         (show desktop)
                                  :k win+r         (Run dialog)
                                  :k alt+f4        (close window)
                                  :k ctrl+shift+esc  (Task Manager)
                                  :k nvda+f12      (NVDA say-time, etc.)
                                  :k win+shift+s   (snipping tool)

INSIDE THE COMMAND PROMPT
  Enter  (or Ctrl+J / Ctrl+M)   run the command
  Esc    (or Ctrl+C)            cancel, return to normal
  Backspace (or Ctrl+H)         delete character

OTHER
  Session auto-reconnects with exponential backoff on a dropped connection.
  On a cert-pin change you'll be prompted interactively (use --trust-new-cert
  to auto-accept in scripts).
"#)
}
