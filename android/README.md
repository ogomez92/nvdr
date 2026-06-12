# nvdr for Android

A native Android **master** client for NVDA Remote. It bridges an Android device
with a hardware keyboard to a remote NVDA running on Windows: speech from the
slave is spoken on the phone via Text-to-Speech, and keystrokes from a paired
Bluetooth/USB keyboard are forwarded back.

Like the iOS app (and unlike the macOS app), it does **not** talk the relay
protocol itself. It SSHes into a bridge host that has the `nvdr` binary and runs
`nvdr --ipc`, then speaks the simple line protocol from [`../src/ipc.rs`](../src/ipc.rs)
over that SSH channel. The Rust side handles TLS, the relay handshake, cert
pinning, and reconnection.

```
Android (this app) ──SSH──▶ bridge host: nvdr --ipc ──TLS──▶ relay ──TLS──▶ slave NVDA (Windows)
        speech ◀──────────────── speak lines ◀───────────────── speech
        keys   ────────────────▶ key lines  ─────────────────▶ keystrokes
```

## Requirements

- A bridge host (Linux/macOS/Windows) reachable over SSH that has the `nvdr`
  binary on its `PATH` (build it from this repo with `cargo build --release`).
- A hardware keyboard paired to the Android device.
- Android 8.0 (API 26) or newer.

## Build

The project targets `compileSdk 36` and needs **JDK 17** plus the Android SDK.

**Android Studio (easiest):** open the `android/` folder. Studio installs any
missing SDK pieces and provides a JDK. Run the `app` configuration.

**Command line:**

```sh
cd android
./gradlew assembleDebug      # → app/build/outputs/apk/debug/app-debug.apk
./gradlew installDebug       # build + install on a connected device (needs adb)
```

`local.properties` points Gradle at the SDK (`sdk.dir=…`). Edit it if your SDK
lives elsewhere. Tooling versions are pinned in `gradle/libs.versions.toml`;
bump them there if Android Studio suggests newer ones.

## Configure

Open **Settings** and fill in:

- **SSH bridge** — host, port, user, and either a password or an OpenSSH private
  key (paste the PEM; encrypted keys take a passphrase). Set the remote command
  if `nvdr` isn't on the default `PATH`.
- **NVDA Remote relay** — relay host/port (default `nvdaremote.com:6837`), the
  channel key shared with the slave, and an optional cert fingerprint. These
  become the `nvdr --ipc` arguments on the bridge.
- **Local input** — which physical key is the NVDA modifier, and how Alt / Meta
  map to Windows modifiers (handy for Mac keyboards).
- **Speech** — TTS rate and voice.

## Use

1. Tap **Connect**. Status goes Connecting → Authenticating → Ready.
2. Flip **Forward keystrokes** on (or press **Caps Lock + F11**). While on,
   mapped keys are sent to the remote and consumed locally; Back/Home/volume
   still work.
3. Speech from the remote NVDA is spoken on the phone; the last line is shown.

Forwarding is focused-only: it works while this app is in the foreground. When
the app is backgrounded, held keys are released on the slave automatically.

## Layout

```
app/src/main/java/com/oriolgomez/nvdr/
  ipc/Ipc.kt          line protocol (mirrors src/ipc.rs, ios/mac IPC.swift)
  input/VK.kt         Windows VK constants (mirrors src/vk.rs)
  input/KeyMap.kt     Android keyCode → VK (analog of mac MacKeyVK)
  settings/           AppSettings (SharedPreferences) + enums
  speech/SpeechOutput.kt   TextToSpeech wrapper
  net/BridgeClient.kt SSHJ driver + reconnect loop
  MainActivity.kt     Compose host + dispatchKeyEvent capture
  ui/                 RootScreen, SettingsScreen, theme
```

See [`AGENTS.md`](AGENTS.md) for architecture notes and invariants.
