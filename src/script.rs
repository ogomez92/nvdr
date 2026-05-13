use std::time::Duration;

use crate::keymap::{self, Transition};

// Any printable text that isn't a combo goes through the clipboard+paste path
// in main.rs::run_script — see Step::Type — so we don't touch per-character
// VK mapping here.

/// One action in a scripted run. Parsed from a single line/token.
pub enum Step {
    /// Send a key chord (e.g. Alt+F4) as nested modifier down/up transitions.
    /// Hotkey bindings on the slave are keyed on VK codes, so this is
    /// layout-independent for letters, digits, and named keys.
    Key(Vec<Transition>),
    /// Paste a literal string. Executed as `set_clipboard_text` + Ctrl+V on
    /// the slave — layout-agnostic and Unicode-safe. Clobbers the slave's
    /// clipboard as a side effect; that's a deliberate tradeoff so `t` works
    /// the same way regardless of whether the slave is US, DE, FR, JP, …
    Type(String),
    /// Pause locally before sending the next step.
    Sleep(Duration),
}

/// Parse a script source into a list of `Step`s.
///
/// Grammar, line-oriented (newlines *and* `;` separate lines):
/// - `# ...`       comment
/// - `k <combo>`   explicit key combo (`keymap::parse_combo` syntax)
/// - `t <text>`    explicit literal text (pasted via clipboard)
/// - `sleep <ms>`  (alias `pause`) local pause in milliseconds
/// - anything else: inferred — try as a combo first, fall back to literal text
///
/// Separator semantics: every `;` or `\n` is itself a `separator_ms` pause.
/// A single separator between two steps yields `separator_ms` of wait; two in
/// a row yields `2 × separator_ms`, and so on, so you can tune timing by just
/// adding more separators (`a;;b` = double wait, `a;;;;b` = quadruple).
/// Leading and trailing whitespace/separators in the source are stripped so
/// ragged input files don't produce dead time at either end.
pub fn parse(source: &str, nvda_vk: u16, separator_ms: u64) -> Result<Vec<Step>, String> {
    let source = source.trim_matches(|c: char| c.is_whitespace() || c == ';');
    let sep = Step::Sleep(Duration::from_millis(separator_ms));
    let mut steps: Vec<Step> = Vec::new();
    let mut buf = String::new();
    let mut buf_line: usize = 1;
    let mut line_no: usize = 1;

    for c in source.chars() {
        if c == ';' || c == '\n' {
            flush_buf(&mut buf, buf_line, nvda_vk, &mut steps)?;
            steps.push(sep_clone(&sep));
            if c == '\n' {
                line_no += 1;
            }
            buf_line = line_no;
        } else {
            if buf.is_empty() {
                buf_line = line_no;
            }
            buf.push(c);
        }
    }
    flush_buf(&mut buf, buf_line, nvda_vk, &mut steps)?;
    Ok(steps)
}

fn flush_buf(
    buf: &mut String,
    line_no: usize,
    nvda_vk: u16,
    steps: &mut Vec<Step>,
) -> Result<(), String> {
    let trimmed = buf.trim();
    if !trimmed.is_empty() && !trimmed.starts_with('#') {
        let step = parse_line(trimmed, nvda_vk)
            .map_err(|e| format!("line {}: {e} (in {:?})", line_no, trimmed))?;
        steps.push(step);
    }
    buf.clear();
    Ok(())
}

fn sep_clone(s: &Step) -> Step {
    match s {
        Step::Sleep(d) => Step::Sleep(*d),
        _ => unreachable!(),
    }
}

fn parse_line(line: &str, nvda_vk: u16) -> Result<Step, String> {
    let (tag, rest) = line
        .split_once(char::is_whitespace)
        .map(|(a, b)| (a, b.trim_start()))
        .unwrap_or((line, ""));
    match tag {
        "k" | "key" => {
            if rest.is_empty() {
                return Err("`k` needs a combo, e.g. `k alt+f4`".into());
            }
            Ok(Step::Key(keymap::parse_combo(rest, nvda_vk)?))
        }
        "t" | "type" => Ok(Step::Type(rest.to_string())),
        "sleep" | "pause" => {
            let ms: u64 = rest
                .parse()
                .map_err(|_| format!("`sleep` needs milliseconds, got {rest:?}"))?;
            Ok(Step::Sleep(Duration::from_millis(ms)))
        }
        // Inference: combo if parse_combo likes it (covers `nvda+t`, `alt+f4`,
        // `enter`, `f1`, and bare single chars), otherwise treat as literal
        // text to be pasted via the clipboard.
        _ => {
            if let Ok(ts) = keymap::parse_combo(line, nvda_vk) {
                Ok(Step::Key(ts))
            } else {
                Ok(Step::Type(line.to_string()))
            }
        }
    }
}

