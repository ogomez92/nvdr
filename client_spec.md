# NVDA Remote — Client Specification

This document describes what a client application must do to connect to an
NVDA Remote relay server and control a remote NVDA instance (the "slave")
already connected to the same channel.

Authoritative sources used:
* `server.py`, `options.py` in this repo — the relay server.
* The NVDA Remote add-on source at `../NVDARemote/addon/globalPlugins/remoteClient/`
  (`transport.py`, `session.py`, `localMachine.py`, `nvda_patcher.py`,
  `input.py`, `serializer.py`, `protocol.py`, `keyboard_hook.py`,
  `bridge.py`, `secureDesktop.py`) — the reference implementation of both
  master and slave endpoints.
* `../NVDARemote/protocol.md` — the add-on's own protocol doc. **Note: it
  is incomplete and wrong in at least one place** (`client_left.client`
  is a dict, not an int). Prefer the source.

Line numbers below refer to the files above.

---

## 1. Transport

* **Protocol:** TCP with mandatory TLS. No plaintext fallback.
  * Server wraps with `ssl.wrap_socket(..., server_side=True)`
    (`server.py:322`).
* **Default port:** `6837` IPv4 and IPv6. Configurable via `--port` /
  `--port6`.
* **Certificate:** By default the server uses a self-signed cert
  (`server.pem`). Clients should **pin the server's cert fingerprint**
  (SHA-256). The reference add-on prompts the user once and caches the
  fingerprint. Do not silently disable verification.
* **Framing:** newline-delimited JSON, UTF-8.
  * One JSON object per line, terminated with `\n` (`0x0A`).
  * Serializer does **not** pass `separators=` to `json.dumps`, so the
    default `(', ', ': ')` spacing is on the wire. Peers must accept
    non-compact JSON — don't assume minified input.
    (`serializer.py:71–89`)
  * Receiver splits on `\n` in a 16 KiB-chunked read loop. A frame
    without `\n` is buffered until it arrives; a frame larger than the
    server's `allowedMessageLength` (default `0` = unlimited) causes the
    server to drop the connection. (`server.py:469–496`)
* **Keep-alive:**
  * **Application layer:** the server sends `{"type":"ping"}` every
    `ping_time` seconds (default `300`) to every client in a channel.
    (`server.py:295–306`, `Channel.ping`). The reference client does
    **not** reply and does not register a handler for `ping`; the
    dispatcher logs "unhandled type" and drops it
    (`transport.py:489–492`). A new client may do the same — no reply
    required.
  * **Socket layer:** the reference client enables OS TCP keep-alive
    with `(on=1, time=60 s, interval=2 s)` via `SIO_KEEPALIVE_VALS`
    (`transport.py:392`). Recommended.
* **TCP options:** the server sets `TCP_NODELAY`; clients should do the
  same. NVDA Remote is latency-sensitive.
* **Protocol version:** `PROTOCOL_VERSION = 2` (`protocol.py:3`). Always
  negotiate 2.

---

## 2. Connection lifecycle

```
  TCP connect → TLS handshake (verify/pin cert)
        │
        ▼
  protocol_version   (version=2)
        │
        ▼
  join               (channel=<key>, connection_type="master")
        │
        ▼
  channel_joined     ◀── from server
  [motd]             ◀── if server has one
  [client_joined]    ◀── for every client already in channel
        │
        ▼
  ── normal relay traffic (both directions) ──
        │
        ▼
  close the socket (no "bye" message)
```

### 2.1 `protocol_version` (client → server)

```json
{"type": "protocol_version", "version": 2}
```

Must be the **first** message sent, before `join`. If the relay doesn't
support your version, it replies with `{"type":"version_mismatch"}`
(empty payload) and drops the connection (`session.py:159–174`). With
version `>= 2`, the server adds `origin` (and, on select messages,
`clients`/`client`) fields to broadcast payloads so you can tell which
peer they came from (`server.py:592–600`).

Source: `transport.py:638–639`.

### 2.2 `join` (client → server)

```json
{
  "type": "join",
  "channel": "123456789",
  "connection_type": "master"
}
```

* `channel` — shared secret / room key (any non-empty string). The
  add-on's key-generator produces a 9-digit numeric string
  (`server.py:572–573`). Treat it like a password; don't log it.
* `connection_type` — `"master"` (controller) or `"slave"` (controlled
  NVDA). For an app that sends hotkeys and receives speech, use
  `"master"`.

Server errors:
* Missing/empty `channel` → `{"type":"error","error":"invalid_parameters"}`
  then socket close (`server.py:524–526`).
* Second `join` on the same connection →
  `{"type":"error","error":"already_joined"}`, no disconnect
  (`server.py:527–529`).

### 2.3 `generate_key` (optional helper)

```json
{"type": "generate_key"}
```

Request a random 9-digit key from the server. Must be sent **before**
`join` on a fresh connection. Server replies:

```json
{"type": "generate_key", "key": "473829165"}
```

…and then marks the socket closeable (`server.py:567–569`). Open a new
connection to actually `join` that key. Used by the add-on's "Host /
Generate Key" dialog.

### 2.4 Server → client messages

| `type` | When | Fields |
|---|---|---|
| `channel_joined` | after your `join` succeeds | `channel` (str), `clients` (list of `{id:int, connection_type:str}`), `user_ids` (list of int — sent by this relay for back-compat; the add-on's handler ignores it), `origin` (int, injected) |
| `motd` | after `join`, if server has an MOTD | `motd` (str), `force_display` (bool) |
| `client_joined` | another client joined your channel | `client` (dict `{id, connection_type}`), `user_id` (int, legacy), `origin` (int, injected) |
| `client_left` | another client disconnected | `client` (dict — **note**: `protocol.md` wrongly says int; source sends a dict, `server.py:174`), `user_id` (int, legacy), `origin` (int) |
| `nvda_not_connected` | you sent a relay message but you're alone in the channel | — |
| `ping` | every `ping_time` seconds | — |
| `error` | protocol error | `error` (str): `"invalid_parameters"` or `"already_joined"` |
| `version_mismatch` | relay rejects your `protocol_version` | — |

All of these may arrive asynchronously. The reference client does not
register handlers for `ping` or `error` — they are logged as
"unhandled" and dropped (`transport.py:489–492`). A new client should
at minimum silence `ping` (no reply needed) and surface `error` /
`version_mismatch` to the user.

### 2.5 Disconnect

Either side closes the TCP socket. There is no `bye` / `leave` message.
The server emits `client_left` to the rest of the channel and reclaims
the id.

---

## 3. Relay messages (application layer)

The server does **not** inspect these. Anything that parses as JSON
with a `type` field is broadcast verbatim to every other client in the
channel (`server.py:498–517`). Malformed (non-JSON) lines are *also*
forwarded as raw bytes. The schemas below are the NVDA Remote add-on's
actual wire format; a real NVDA running the add-on as slave will only
obey messages that match exactly.

### 3.1 JSON encoding rules

* Every message is a JSON object on one line, terminated with `\n`.
* The `type` field is a raw string (one of the `RemoteMessageType` enum
  values, `protocol.py:5–38`).
* The serializer does **not** minify JSON (default `json.dumps`
  spacing).
* No bare `bytes` or `Enum` values in payloads — they will crash
  `json.dumps`. If you're wrapping an NVDA-internal object, flatten it
  to plain JSON types first.
* **SpeechCommand serialization** (only used inside `speak.sequence`):
  each non-string item is a 2-element JSON array
  `[ClassName, attrs_dict]`. `ClassName` is a `speech.commands`
  attribute name (e.g. `"PitchCommand"`, `"RateCommand"`,
  `"LangChangeCommand"`, `"BreakCommand"`, `"IndexCommand"`,
  `"CharacterModeCommand"`, `"PhonemeCommand"`, `"EndUtteranceCommand"`).
  `attrs_dict` is the command's `__dict__`. Unknown class names are
  silently dropped by the receiver (`serializer.py:151–180`).
* **Deserialization of command objects only runs for `speak`** — the
  receiver only reconstructs `[ClassName, attrs]` tuples when
  `type == "speak"` and a `sequence` key is present
  (`serializer.py:91–104`). In any other message type, lists stay as
  lists.

### 3.2 Master → Slave (what your app sends)

#### `key` — one keyboard transition

```json
{
  "type": "key",
  "vk_code": 65,
  "scan_code": 30,
  "extended": false,
  "pressed": true
}
```

* `vk_code` (int, required) — Windows virtual-key code.
* `scan_code` (int, required) — hardware scan code. **Observation:** the
  reference slave's `LocalMachine.sendKey` passes `scan=None` to
  `input.send_key`, which lets Windows recompute the scan via
  `MapVirtualKeyW` (`localMachine.py:282–295`, `input.py:128–140`). So
  `scan_code` is effectively ignored *today*, but the field is required
  and the add-on always sends it (see `keyboard_hook.py:59`). Send a
  real scan code when you have one; `0` is a safe placeholder for
  printable keys.
* `extended` (bool, required) — extended-key flag
  (`KEYEVENTF_EXTENDEDKEY`). Right-hand modifiers, arrows, numpad
  Enter, and the Insert/Delete/Home/End/PageUp/PageDown cluster outside
  the numpad are "extended". The distinction matters for NVDA key
  bindings (e.g. numpad Insert vs. main-row Insert).
* `pressed` (bool, required) — `true` = key-down, `false` = key-up.

One message = one transition. For `Ctrl+A`:
1. `Ctrl` down
2. `A` down
3. `A` up
4. `Ctrl` up

Always send matching key-ups. If your app exits mid-chord, the slave
holds modifiers down. `RemoteClient.releaseKeys` in the add-on
(`client.py:460–462`) sends synthetic key-ups on disengage — your
client should do the same on disconnect/shutdown/focus loss.

Source: `client.py:438`.

#### `send_SAS` — Ctrl+Alt+Del

```json
{"type": "send_SAS"}
```

No fields. Slave calls `ctypes.windll.sas.SendSAS(0)` if it has
UI Access; otherwise it speaks a warning and does nothing
(`localMachine.py:307–317`). Expect it to be a no-op unless the
operator installed NVDA as a service / enabled UI Access.

Source: `client.py:192`.

#### `braille_input` — forward a braille-display gesture

```json
{
  "type": "braille_input",
  "source": "freedomScientific",
  "model": "Focus 40",
  "id": "dot4+dot5",
  "dots": 24,
  "space": false,
  "routingIndex": 7,
  "scriptPath": ["globalCommands", "GlobalCommands", "kb:alt"]
}
```

All fields optional at the JSON level; in practice the add-on collects
any scalar (`int`/`str`/`bool`) attribute from the local gesture plus a
hand-picked set (`nvda_patcher.py:91–130`). The slave reconstructs a
`BrailleInputGesture` and executes it via `inputCore.manager`
(`input.py:61–126`, `localMachine.py:228–243`). Notes:

* `source` gets prefixed with `"remote"` on the slave
  (`"freedomScientific"` → `"remoteFreedomScientific"`) so it resolves
  against the remote binding set, not the local one.
* `scriptPath` is a three-element `[module, class, script]` list. If
  `script` starts with `"kb:"`, the slave re-emulates keyboard input
  instead of looking up a script (`input.py:76–78`).
* `routingIndex` is camelCase.

Only relevant for clients that expose a braille display.

Source: `session.py:554–555`.

#### `set_braille_info` — advertise your braille display

```json
{"type": "set_braille_info", "name": "noBraille", "numCells": 0}
```

* `name` (str, required) — the local braille driver name. Send
  `"noBraille"` with `numCells: 0` if you have no display.
* `numCells` (int, required, camelCase).

Send once after `join`, and again whenever your display changes. The
slave uses this to decide whether to emit `display` messages at all
(`session.py:440–447`).

Source: `session.py:550–552`.

#### `set_clipboard_text` — push text to the peer's clipboard

```json
{"type": "set_clipboard_text", "text": "..."}
```

Bidirectional in the protocol — either master or slave may send; the
receiver copies into its OS clipboard and plays a "clipboard received"
cue (`localMachine.py:297–305`). Fire-and-forget; no echo.

Source: `client.py:180`.

### 3.3 Slave → Master (what your app receives)

#### `speak`

```json
{
  "type": "speak",
  "sequence": ["Hello, ", ["PitchCommand", {"offset": 20}], "world"],
  "priority": "normal"
}
```

* `sequence` (list, required) — mixed strings and `[ClassName, attrs]`
  SpeechCommand pairs (see §3.1).
* `priority` (str, required) — NVDA speech priority: `"now"`, `"next"`,
  or `"normal"`.

A minimal client can ignore the command entries and concatenate the
string entries to get the spoken text. Speech callback / cancellable
commands (`BaseCallbackCommand`, `_CancellableSpeechCommand`) are
filtered out by the slave before send (`session.py:87–91`), so you
won't receive those.

Source: `session.py:429–433`.

#### `cancel`

```json
{"type": "cancel"}
```

No fields. Interrupt any in-flight utterances in your local TTS.
Emitted by the slave whenever NVDA's `speechCanceled` extension point
fires (`session.py:314–315`).

#### `pause_speech`

```json
{"type": "pause_speech", "switch": true}
```

`switch=true` → pause; `switch=false` → resume. (`session.py:438`)

#### `tone`

```json
{"type": "tone", "hz": 440, "length": 50, "left": 50, "right": 50}
```

* `hz` (number), `length` (number, ms), `left`/`right` (int 0–100).

Emitted whenever NVDA's `tones.decide_beep` fires on the slave
(`session.py:312–313`). The master receiver defaults `left`/`right` to
50 if missing (`localMachine.py:140–154`).

#### `wave`

```json
{"type": "wave", "fileName": "C:\\Program Files\\NVDA\\waves\\focusMode.wav", "asynchronous": true}
```

* `fileName` (str, required) — **absolute path on the slave's machine.**
  The master plays it via `nvwave.playWaveFile(fileName)` and silently
  skips if the path doesn't exist locally (`localMachine.py:132–137`).
  This means a non-NVDA client without NVDA installed at the same
  location will never hear these sounds. A reasonable strategy is to
  map known basenames (e.g. `focusMode.wav`) to your own sound set.
* `asynchronous` (bool, optional) — forwarded but the reference master
  always plays async regardless.
* Any additional kwargs from `nvwave.decide_playWaveFile` ride along
  and are ignored by the master.

Source: `session.py:316–318`.

#### `display`

```json
{"type": "display", "cells": [0, 45, 17, 0, 0, ...]}
```

* `cells` (list of int 0–255) — braille cells. Each byte is a bitmask:
  dot1=1, dot2=2, dot3=4, dot4=8, dot5=16, dot6=32, dot7=64, dot8=128.

Only sent when the master previously advertised `numCells > 0` via
`set_braille_info` (`session.py:440–447`). The master writes them via
`braille.handler._writeCells`, padding/truncating to its own display
size (`localMachine.py:206–226`).

#### `set_clipboard_text`

Same schema as §3.2; also flows slave → master when the slave pushes
its clipboard. Handle identically in both directions.

### 3.4 Messages you can safely ignore

These are declared in the enum but won't reach an external master in
normal operation:

* `index` — dead code. Declared in `protocol.py:22`, never sent, never
  handled. Not in `protocol.md`.
* `set_display_size` — only used inside the secure-desktop bridge (SD
  NVDA ↔ user-session NVDA over a local loopback relay,
  `secureDesktop.py:199–205`). An external master will not see it.
* `nvda_not_connected` — has a master-side handler
  (`session.py:499–501`) that cancels speech and announces "Remote
  NVDA not connected." The server was meant to send it but
  `protocol.py:38` explicitly notes: *"added in version 2 but never
  implemented on the server."* Install the handler for future-proofing,
  but don't rely on it firing.

### 3.5 `origin` field

The relay server injects `origin` (int, sender's client id) into every
broadcast message it forwards when `protocol_version >= 2`
(`server.py:592–600`). All inbound handlers must accept this extra
kwarg — either explicitly (`origin=None`) or via `**kwargs`. Several
add-on handlers key off it (e.g. `SlaveSession.handleBrailleInfo` looks
up `self.masters[origin]`, `session.py:382–392`).

---

## 4. Minimum viable master client

To build an app that sends hotkeys and hears speech from a remote NVDA:

1. TCP-connect to `host:6837`, wrap in TLS, pin/verify the cert.
   Enable `TCP_NODELAY` and `SO_KEEPALIVE`.
2. Send `{"type":"protocol_version","version":2}\n`.
3. Send `{"type":"join","channel":"<key>","connection_type":"master"}\n`.
4. (Optional) Send `{"type":"set_braille_info","name":"noBraille","numCells":0}\n`.
5. Start a read loop: split inbound bytes on `\n`, parse each line as
   JSON, dispatch on `type`:
   * `channel_joined` → inspect `clients`; if no slave is present, show
     "waiting for NVDA".
   * `motd` → display to user.
   * `client_joined` / `client_left` → update peer list; on a slave
     leaving, update UI.
   * `nvda_not_connected` → `cancel` local TTS, show message.
   * `speak` → for each string entry in `sequence`, feed to local TTS.
     Respect `priority` (`"now"` should interrupt).
   * `cancel` → stop local TTS.
   * `pause_speech` → pause/resume local TTS per `switch`.
   * `tone` / `wave` → play sound, or ignore.
   * `display` → render to braille, or ignore.
   * `set_clipboard_text` → copy to OS clipboard.
   * `ping` → no-op.
   * `error` / `version_mismatch` → surface to user; close.
   * anything else → ignore (don't crash on unknown types).
6. On a user keypress, emit a pair of `key` messages (down + up, plus
   down/up for each modifier in the correct nesting order) with
   `vk_code`, `scan_code`, `extended`, `pressed`.
7. For text injection that doesn't map cleanly to keycodes, there is
   **no `type` message** in this protocol — it's not part of the enum.
   Use `set_clipboard_text` followed by a `key` Ctrl+V instead.
   *(Earlier drafts of this spec listed a `type` message; that was
   wrong — the add-on has no such type.)*
8. On shutdown/disconnect, send key-up messages for any modifiers or
   keys you believe you've pressed down (see the add-on's
   `releaseKeys`, `client.py:460–462`), then close the socket.

A client that implements steps 1–6 with `key`, `speak`, and `cancel`
alone is already a functional NVDA Remote master.

---

## 5. Gotchas

1. **No `type` message for text.** Unlike some other remote-accessibility
   protocols, NVDA Remote has no "inject Unicode string" message. Use
   `set_clipboard_text` + a synthesized Ctrl+V keypress pair instead.
   Earlier drafts of this document had a `type` message — that was a
   fabrication; the add-on's `RemoteMessageType` enum has no such
   value.
2. **Every message needs a trailing `\n`.** Omitting it looks like a
   hang — the server buffers forever (`server.py:488–490`).
3. **Send `protocol_version` before `join`.** Doing it after is a no-op
   for the `channel_joined` fields you already received.
4. **Relay messages sent before `join` are silently dropped by the
   server** (`server.py:515–517`).
5. **`nvda_not_connected` means you're alone in the channel**, not that
   the slave crashed. The relay server only emits it when you try to
   relay while alone (`server.py:509–511`).
6. **Echo semantics.** Your own messages are **not** echoed back to
   you (`server.py:620–640`, `send_to_others` filters self). Don't use
   the relay as a loopback.
7. **Non-JSON garbage is forwarded verbatim.** The server doesn't
   validate outgoing payloads; broken frames reach the slave and may
   crash strict peers.
8. **Modifier leaks.** Always release keys you pressed.
9. **`allowedMessageLength`.** If the operator set a cap and you send a
   larger `speak`/`display`/`set_clipboard_text`, the server
   disconnects silently (`server.py:484–487`). Default is unlimited.
10. **Field naming is inconsistent.** Most fields are snake_case
    (`vk_code`, `scan_code`, `connection_type`, `force_display`,
    `pause_speech.switch`) but a few are camelCase: `set_braille_info.numCells`,
    `braille_input.routingIndex`, `wave.fileName`. Match exactly —
    the slave does attribute assignment directly from the JSON keys.
11. **Unknown kwargs crash handlers.** The reference dispatcher calls
    `wx.CallAfter(handler, **obj)` after removing `type`
    (`transport.py:493`). If a future server adds a new field and your
    handler signature doesn't accept it, you'll raise. Prefer
    `**kwargs` on all handlers for forward compatibility.
12. **`wave.fileName` is a slave-side absolute path.** A non-NVDA
    client will usually not have that file. Drop silently or map
    basenames to your own assets.
13. **Speech command objects only deserialize inside `speak`.** If you
    ever invent a new message that carries SpeechCommand lists, the
    reference client will leave them as `[ClassName, {...}]` JSON
    arrays — the `as_sequence` hook only fires for `type == "speak"`
    (`serializer.py:151–180`).
14. **`protocol.md` is not authoritative.** In particular,
    `client_left.client` is documented as an `integer` but the server
    and add-on both use a dict. When in doubt, read the source.
