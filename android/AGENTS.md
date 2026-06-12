# Agent guide for the Android port

This is the native Android build of nvdr. It plays the same role as `../ios`:
bridge an Android device with a hardware (Bluetooth/USB) keyboard to a remote
NVDA over SSH → `nvdr --ipc`, speak the slave's speech with on-device TTS, and
forward keystrokes back. Like the iOS port (and unlike `../mac`), capture is
**focused-only** — keys are intercepted while the nvdr Activity is foreground.

## Role

You are a **Senior Android Engineer**, specializing in Kotlin and Jetpack
Compose. Follow modern Android conventions and keep the app accessible — its
users lean on TalkBack.

## Core instructions

- Kotlin + Jetpack Compose (Material 3). No XML layouts; Compose only.
- Coroutines + `StateFlow` for async and state. No RxJava, no `LiveData`.
- `minSdk 26`, `compileSdk`/`targetSdk 36`, JDK 17.
- Don't add third-party libraries without asking. The deliberate ones are:
  - **SSHJ** (`com.hierynomus:sshj`) — SSH transport. Picked over JSch because
    it supports ed25519 and rsa-sha2 out of the box, so we do **not** reimplement
    the RSA-SHA2 signing dance the Swift ports needed for Citadel. BouncyCastle +
    eddsa are its transitive crypto deps; `NvdrApp` swaps Android's stripped `BC`
    provider for the full one so key parsing works.
  - **Material Icons Extended** — UI glyphs.

## Architecture (read in this order)

The data flow mirrors the Rust/Swift ports. Shared wire contracts live one level
up: `../client_spec.md` (relay protocol) and `../src/ipc.rs` (the line protocol
this app speaks). When you touch anything that shapes a wire message, consult
those first.

1. **`ipc/Ipc.kt`** — `IpcCommand` (serialize) / `IpcEvent` (parse) for the
   line protocol from `src/ipc.rs`. A direct port of the Swift `IPC.swift`. We
   send `key <vk> <0|1>`, `combo`, `type`, `sas`, `release_all`, `quit`; we
   receive `speak`, `cancel`, `state`, `error`. The `type` escaping (`\n \r \t
   \\`) must stay in lockstep with the Rust `unescape`.
2. **`input/VK.kt`** — Windows VK constants. Mirrors `src/vk.rs` and the Swift
   `VK.swift`; every port must agree on these values.
3. **`input/KeyMap.kt`** — Android `KeyEvent` keyCode → VK. The analog of the
   macOS `MacKeyVK`. Alt/Meta route through the user's `ModifierMapping` (for
   Mac keyboards paired to Android). US layout assumed. **`KeyMap` and the iOS
   `HIDToVK` / mac `MacKeyVK` don't share a table** — add a named key to all of
   them when you add one here.
4. **`settings/`** — `AppSettings` (SharedPreferences, same `nvdr.*` keys as the
   Swift `UserDefaults` store) + the `NvdaModifier` / `ModifierMapping` /
   `SSHAuthMode` enums. `remoteCommand()` shell-quotes the `nvdr --ipc` argv
   exactly like the Swift `remoteCommand()`.
5. **`speech/SpeechOutput.kt`** — `TextToSpeech` wrapper. Speaks as
   `USAGE_ASSISTANCE_ACCESSIBILITY`. Early utterances buffer until the engine
   initializes.
6. **`net/BridgeClient.kt`** — the SSHJ driver. Opens an exec channel running
   `nvdr --ipc`, runs the line protocol, routes `speak` to `SpeechOutput`,
   pushes keys back. Auto-reconnects the SSH link with 500 ms→30 s backoff. The
   relay-level `state disconnected`/`ready` events nvdr emits are informational
   and never tear down the SSH session.
7. **`MainActivity.kt`** — hosts Compose and captures the keyboard via
   `dispatchKeyEvent`. When forwarding is on, mapped keys are consumed and sent;
   unmapped keys (Back, volume) fall through. Caps Lock+F11 toggles forwarding
   (mirroring NVDA+F11). `onPause` sends `release_all` so a backgrounded app
   can't latch a modifier on the slave.
8. **`ui/`** — `RootScreen` (status, connect, forwarding, last speech, log) and
   `SettingsScreen` (SSH / relay / input / speech).

## Non-obvious invariants

- **Every `key` line is `key <vk> <0|1>`** with a decimal Windows VK. nvdr fills
  in scan_code/extended downstream; don't try to add them here.
- **Forwarding is gated in `MainActivity`, not `BridgeClient`.** `BridgeClient`
  forwards whatever it's told. Toggling forwarding off sends `release_all`.
- **`KeyMap` returns `null` for unmapped keys and the caller must let the system
  handle them** — otherwise Back/Home/volume break while forwarding.
- **The BouncyCastle provider swap in `NvdrApp.onCreate` is load-bearing** for
  SSHJ on Android. Don't remove it.
- **Auto-repeat is dropped** (`event.repeatCount == 0` gate on key-down) so held
  keys don't flood the wire; key-up always sends.

## Build

```sh
./gradlew assembleDebug      # apk in app/build/outputs/apk/debug/
./gradlew installDebug       # build + install on a connected device
./gradlew lint
```

Needs JDK 17 and the Android SDK (compileSdk 36 / build-tools installed).
Opening the `android/` folder in Android Studio handles both automatically.
