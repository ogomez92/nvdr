use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::vk::*;

/// Abstract key transition we will turn into a JSON `key` message.
#[derive(Debug, Clone, Copy)]
pub struct Transition {
    pub vk: u16,
    pub pressed: bool,
}

impl Transition {
    pub fn down(vk: u16) -> Self {
        Self { vk, pressed: true }
    }
    pub fn up(vk: u16) -> Self {
        Self { vk, pressed: false }
    }
}

/// The main VK for the key plus whether Shift needs to be held to produce the
/// printable character. `shift_required` is used by the caller to decide
/// whether to bracket with VK_SHIFT down/up when the user did not already hold
/// Shift (e.g. they pressed `!` on a US layout).
pub struct MappedKey {
    pub vk: u16,
    pub shift_required: bool,
}

/// Map a crossterm `KeyEvent` to a series of `Transition`s, including any
/// synthesized modifier bracketing.
///
/// Returns `None` for keys we don't know how to send (e.g. unmapped Unicode).
pub fn key_event_to_transitions(ev: &KeyEvent) -> Option<Vec<Transition>> {
    let mapped = map_code(&ev.code)?;

    // Combine the event's modifiers with modifiers required by the character
    // itself (Shift for shifted punctuation / uppercase letters).
    let mut need_ctrl = ev.modifiers.contains(KeyModifiers::CONTROL);
    let mut need_alt = ev.modifiers.contains(KeyModifiers::ALT);
    let mut need_shift = ev.modifiers.contains(KeyModifiers::SHIFT) || mapped.shift_required;

    // Crossterm already reports uppercase letters for Shift+letter; if
    // shift_required was set by map_code (uppercase letter or shifted punct)
    // we should hold Shift.
    let _ = (&mut need_ctrl, &mut need_alt, &mut need_shift);

    let mut out: Vec<Transition> = Vec::with_capacity(8);
    if need_ctrl {
        out.push(Transition::down(VK_CONTROL));
    }
    if need_alt {
        out.push(Transition::down(VK_MENU));
    }
    if need_shift {
        out.push(Transition::down(VK_SHIFT));
    }
    out.push(Transition::down(mapped.vk));
    out.push(Transition::up(mapped.vk));
    if need_shift {
        out.push(Transition::up(VK_SHIFT));
    }
    if need_alt {
        out.push(Transition::up(VK_MENU));
    }
    if need_ctrl {
        out.push(Transition::up(VK_CONTROL));
    }
    Some(out)
}

fn map_code(code: &KeyCode) -> Option<MappedKey> {
    Some(match code {
        KeyCode::Backspace => mk(VK_BACK, false),
        KeyCode::Enter => mk(VK_RETURN, false),
        KeyCode::Left => mk(VK_LEFT, false),
        KeyCode::Right => mk(VK_RIGHT, false),
        KeyCode::Up => mk(VK_UP, false),
        KeyCode::Down => mk(VK_DOWN, false),
        KeyCode::Home => mk(VK_HOME, false),
        KeyCode::End => mk(VK_END, false),
        KeyCode::PageUp => mk(VK_PRIOR, false),
        KeyCode::PageDown => mk(VK_NEXT, false),
        KeyCode::Tab => mk(VK_TAB, false),
        KeyCode::BackTab => mk(VK_TAB, true),
        KeyCode::Delete => mk(VK_DELETE, false),
        KeyCode::Insert => mk(VK_INSERT, false),
        KeyCode::F(n) if *n >= 1 && *n <= 24 => mk(VK_F1 + (*n as u16 - 1), false),
        KeyCode::Esc => mk(VK_ESCAPE, false),
        KeyCode::Char(c) => map_char(*c)?,
        _ => return None,
    })
}

fn mk(vk: u16, shift: bool) -> MappedKey {
    MappedKey {
        vk,
        shift_required: shift,
    }
}

fn map_char(c: char) -> Option<MappedKey> {
    let vk = match c {
        ' ' => return Some(mk(VK_SPACE, false)),
        '\t' => return Some(mk(VK_TAB, false)),
        '\r' | '\n' => return Some(mk(VK_RETURN, false)),
        'a'..='z' => (c as u16).wrapping_sub('a' as u16) + 0x41,
        'A'..='Z' => return Some(mk((c as u16) - ('A' as u16) + 0x41, true)),
        '0'..='9' => (c as u16) - ('0' as u16) + 0x30,
        // US-layout punctuation, unshifted
        '`' => return Some(mk(VK_OEM_3, false)),
        '-' => return Some(mk(VK_OEM_MINUS, false)),
        '=' => return Some(mk(VK_OEM_PLUS, false)),
        '[' => return Some(mk(VK_OEM_4, false)),
        ']' => return Some(mk(VK_OEM_6, false)),
        '\\' => return Some(mk(VK_OEM_5, false)),
        ';' => return Some(mk(VK_OEM_1, false)),
        '\'' => return Some(mk(VK_OEM_7, false)),
        ',' => return Some(mk(VK_OEM_COMMA, false)),
        '.' => return Some(mk(VK_OEM_PERIOD, false)),
        '/' => return Some(mk(VK_OEM_2, false)),
        // Shifted punctuation
        '~' => return Some(mk(VK_OEM_3, true)),
        '!' => return Some(mk(0x31, true)),
        '@' => return Some(mk(0x32, true)),
        '#' => return Some(mk(0x33, true)),
        '$' => return Some(mk(0x34, true)),
        '%' => return Some(mk(0x35, true)),
        '^' => return Some(mk(0x36, true)),
        '&' => return Some(mk(0x37, true)),
        '*' => return Some(mk(0x38, true)),
        '(' => return Some(mk(0x39, true)),
        ')' => return Some(mk(0x30, true)),
        '_' => return Some(mk(VK_OEM_MINUS, true)),
        '+' => return Some(mk(VK_OEM_PLUS, true)),
        '{' => return Some(mk(VK_OEM_4, true)),
        '}' => return Some(mk(VK_OEM_6, true)),
        '|' => return Some(mk(VK_OEM_5, true)),
        ':' => return Some(mk(VK_OEM_1, true)),
        '"' => return Some(mk(VK_OEM_7, true)),
        '<' => return Some(mk(VK_OEM_COMMA, true)),
        '>' => return Some(mk(VK_OEM_PERIOD, true)),
        '?' => return Some(mk(VK_OEM_2, true)),
        _ => return None,
    };
    Some(mk(vk, false))
}

/// Parse a `+`-separated key combo like `win+m`, `ctrl+shift+esc`,
/// `nvda+f12`. The last token is the base key; all others are modifiers.
/// `nvda_vk` lets the caller decide whether NVDA = Insert or CapsLock.
/// Returns the full down/up transition list, in proper modifier-nested order.
pub fn parse_combo(spec: &str, nvda_vk: u16) -> Result<Vec<Transition>, String> {
    let parts: Vec<&str> = spec.split('+').map(|s| s.trim()).filter(|s| !s.is_empty()).collect();
    if parts.is_empty() {
        return Err("empty key spec".into());
    }
    let (base, mods) = parts.split_last().unwrap();
    let mut mod_vks: Vec<u16> = Vec::with_capacity(mods.len());
    for m in mods {
        let vk = match m.to_ascii_lowercase().as_str() {
            "ctrl" | "control" => VK_CONTROL,
            "alt" | "menu" => VK_MENU,
            "shift" => VK_SHIFT,
            "win" | "super" | "meta" | "lwin" => VK_LWIN,
            "rwin" => VK_RWIN,
            "nvda" | "ins" => nvda_vk,
            "caps" | "capslock" => VK_CAPITAL,
            other => return Err(format!("unknown modifier: {other}")),
        };
        if !mod_vks.contains(&vk) {
            mod_vks.push(vk);
        }
    }
    let base_mapped = parse_named_key(base)
        .ok_or_else(|| format!("unknown key: {base}"))?;
    // If the base requires Shift to type (e.g. `?`) and the user didn't
    // already include it, add it.
    let mut shift_added = false;
    if base_mapped.shift_required && !mod_vks.contains(&VK_SHIFT) {
        mod_vks.push(VK_SHIFT);
        shift_added = true;
    }
    let _ = shift_added;
    let mut out = Vec::with_capacity(mod_vks.len() * 2 + 2);
    for m in &mod_vks {
        out.push(Transition::down(*m));
    }
    out.push(Transition::down(base_mapped.vk));
    out.push(Transition::up(base_mapped.vk));
    for m in mod_vks.iter().rev() {
        out.push(Transition::up(*m));
    }
    Ok(out)
}

fn parse_named_key(name: &str) -> Option<MappedKey> {
    let n = name.to_ascii_lowercase();
    // Function keys: f1..f24
    if let Some(rest) = n.strip_prefix('f') {
        if let Ok(num) = rest.parse::<u16>() {
            if (1..=24).contains(&num) {
                return Some(mk(VK_F1 + num - 1, false));
            }
        }
    }
    let vk = match n.as_str() {
        "enter" | "return" | "ret" | "cr" => VK_RETURN,
        "tab" => VK_TAB,
        "space" | "spc" => VK_SPACE,
        "esc" | "escape" => VK_ESCAPE,
        "backspace" | "bs" | "back" => VK_BACK,
        "delete" | "del" => VK_DELETE,
        "insert" | "ins" => VK_INSERT,
        "home" => VK_HOME,
        "end" => VK_END,
        "pageup" | "pgup" | "prior" => VK_PRIOR,
        "pagedown" | "pgdn" | "pgdown" | "next" => VK_NEXT,
        "up" => VK_UP,
        "down" => VK_DOWN,
        "left" => VK_LEFT,
        "right" => VK_RIGHT,
        "capslock" | "caps" => VK_CAPITAL,
        "apps" | "menu_key" => VK_APPS,
        "numlock" => VK_NUMLOCK,
        // single character — defer to map_char
        _ if n.chars().count() == 1 => {
            return map_char(n.chars().next().unwrap());
        }
        _ => return None,
    };
    Some(mk(vk, false))
}

pub fn vk_name(vk: u16) -> String {
    match vk {
        VK_CONTROL | VK_LCONTROL => "Ctrl".into(),
        VK_SHIFT | VK_LSHIFT => "Shift".into(),
        VK_MENU | VK_LMENU => "Alt".into(),
        VK_INSERT => "Insert".into(),
        VK_CAPITAL => "CapsLock".into(),
        VK_BACK => "Backspace".into(),
        VK_RETURN => "Enter".into(),
        VK_TAB => "Tab".into(),
        VK_ESCAPE => "Esc".into(),
        VK_SPACE => "Space".into(),
        VK_DELETE => "Delete".into(),
        VK_HOME => "Home".into(),
        VK_END => "End".into(),
        VK_PRIOR => "PageUp".into(),
        VK_NEXT => "PageDown".into(),
        VK_UP => "Up".into(),
        VK_DOWN => "Down".into(),
        VK_LEFT => "Left".into(),
        VK_RIGHT => "Right".into(),
        VK_F1..=0x87 => format!("F{}", vk - VK_F1 + 1),
        0x41..=0x5A => ((vk as u8) as char).to_string(),
        0x30..=0x39 => ((vk as u8) as char).to_string(),
        _ => format!("VK_0x{vk:02X}"),
    }
}
