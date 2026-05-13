# nvdr scripting

`nvdr` has a one-shot, non-interactive mode for scripts and AI workflows:
connect, fire a prepared sequence of keystrokes and text, capture any NVDA
speech that comes back for a couple of seconds, print it on **stdout**, and
exit. All connection chatter, warnings, and server errors go to **stderr**,
so stdout is clean for piping into another tool.

## Invocation

Two entry points — same grammar:

```sh
# Inline — separate steps with `;` or newlines.
nvdr -c 123456789 -k 'nvda+t; alt+f4; win+d'

# From a file.
nvdr -c 123456789 -s script.txt
```

Relevant flags:

| Flag                 | Default | Meaning                                                                 |
| -------------------- | ------- | ----------------------------------------------------------------------- |
| `-k, --keys <STR>`   |         | Steps as an inline string.                                              |
| `-s, --script <FILE>`|         | Steps from a file.                                                      |
| `--wait-ms <N>`      | `2000`  | How long to collect NVDA speech after the last step before exiting.     |
| `--separator-ms <N>` | `250`   | Milliseconds each separator (`;` / newline) contributes (see below).    |

All the usual connection flags (`-H`, `-p`, `-c`, `--fingerprint`,
`--insecure`, `--pin-file`, `--trust-new-cert`) apply in script mode too.

## Grammar

One step per line. Both `\n` and `;` count as line separators — that means
an inline `-k "a; b"` and a two-line file `a\nb` behave identically.

| Form          | Meaning                                                                              | Example                |
| ------------- | ------------------------------------------------------------------------------------ | ---------------------- |
| `k <combo>`   | Key combo (same syntax as interactive `:k`). VK-based, layout-independent for letters/digits/named keys. | `k ctrl+shift+esc` |
| `t <text>`    | Literal text, pasted via the slave's clipboard. Layout-agnostic, Unicode-safe. Clobbers the slave's clipboard. | `t Привет, мир!`       |
| `sleep <ms>`  | Precise local pause. Alias: `pause <ms>`.                                             | `sleep 500`            |
| `<combo>`     | Inferred combo — anything `parse_combo` accepts (e.g. `alt+f4`, `nvda+t`, `enter`, `f1`). | `nvda+t`               |
| `<text>`      | Inferred literal text — fall-through when it isn't a combo.                          | `hello how are you?`   |
| `# …`         | Comment. Ignored.                                                                    | `# open run dialog`    |

Inference rule: a line is a combo if `keymap::parse_combo` accepts it;
otherwise it's pasted as literal text. Use the explicit `k` / `t` prefix
when inference would guess wrong — e.g. to type a literal `+`, or a word
like `enter` that would otherwise parse as a key name.

## Separators as timing

Every `;` or newline is itself a **`--separator-ms` pause** (default 250 ms).
Chain separators to lengthen the wait:

| Source         | Wait between `a` and `b` |
| -------------- | ------------------------ |
| `a; b`         | 250 ms                   |
| `a;; b`        | 500 ms                   |
| `a;;;; b`      | 1000 ms                  |
| `a\n\nb`       | 500 ms                   |

This works the same in files and in inline `-k` strings. Blank lines in a
file are separators, so:

```
win+r


notepad
enter
```

…has 500 ms between `win+r` and `notepad`, and 250 ms between `notepad`
and `enter`.

Leading and trailing whitespace/separators in the source are stripped, so
a ragged file doesn't produce dead time at either end.

For pauses finer than `separator_ms`, use an explicit `sleep`:

```
win+r
sleep 600
notepad
```

`sleep` adds on top of the surrounding separators — `win+r; sleep 600;
notepad` waits `250 + 600 + 250 = 1100 ms`, since you can't have two steps
without at least one separator between them. If precise timing matters,
think in total-pause terms: pick whichever combination of separators and
`sleep`s sums to what you want.

## Example: open Notepad, read its title

```
# script.txt — open Notepad via the Run dialog and have NVDA read the title.
win+r
;;;
notepad
enter
;;;
nvda+t
```

Run and capture:

```sh
nvdr -c 123456789 -s script.txt > title.txt 2> nvdr.log
```

Stdout contains just the NVDA speech lines.

## Example: one-liner

```sh
nvdr -c 123456789 -k 'win+r;; notepad; enter;;;; nvda+t'
```

## Extending the grammar

The parser lives in `src/script.rs`. To add a new line form, add a match
arm in `parse_line` (and a variant to `Step` if it maps to a new kind of
action). To change the separator character set, edit the `c == ';' ||
c == '\n'` check in `parse`.
