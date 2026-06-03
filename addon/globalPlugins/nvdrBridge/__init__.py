"""nvdrBridge — drive the nvdr master client from inside NVDA.

The plugin spawns `nvdr --ipc` as a subprocess **on demand** — it does not
connect at NVDA startup. The first NVDA+F11 press starts the subprocess and
dials the relay; once `state ready` arrives, subsequent NVDA+F11 presses
toggle passthrough. While passthrough is on the plugin reads the subprocess's
speech events back into local speech and intercepts every keystroke,
forwarding it as a raw VK transition.

Why a subprocess and not a direct TLS client in Python: the nvdr binary
already does TLS pinning, protocol-v2 framing, version-mismatch handling,
held-key tracking, and reconnect/backoff. Reusing it via IPC keeps that logic
in one place (Rust, tested) and keeps this add-on a thin shim.
"""

import os
import shlex
import sys
import subprocess
import threading

import addonHandler
import globalPluginHandler
import scriptHandler
import config
import speech
import ui
import wx
import keyboardHandler
try:
    import winInputHook  # type: ignore
except Exception:
    winInputHook = None  # type: ignore
from logHandler import log
from gui.settingsDialogs import SettingsPanel, NVDASettingsDialog
from gui import guiHelper, nvdaControls

addonHandler.initTranslation()

# --- VK constants we look at directly. Hardcoded so we don't import a
# Windows-only header in code that NVDA's static analyzers might preload.
VK_CAPITAL = 0x14
VK_INSERT = 0x2D
VK_F11 = 0x7A

# CreationFlag for Popen on Windows that prevents a console window from
# flashing when nvdr launches.
_CREATE_NO_WINDOW = 0x08000000


confspec = {
    # -- SSH (the bridge transport) --
    "sshCommand": 'string(default="ssh")',
    "sshHost": 'string(default="")',
    "sshPort": "integer(default=22, min=1, max=65535)",
    "sshUser": 'string(default="")',
    "sshExtraArgs": 'string(default="")',
    # -- Remote nvdr invocation (what runs on the bridge box) --
    "remoteNvdrCommand": 'string(default="nvdr")',
    # -- NVDA Remote relay (the host nvdr itself dials out to) --
    "relayHost": 'string(default="nvdaremote.com")',
    "relayPort": "integer(default=6837, min=1, max=65535)",
    "channel": 'string(default="")',
    "fingerprint": 'string(default="")',
    "insecure": "boolean(default=False)",
    # How many consecutive failed connection attempts before we stop retrying
    # and wait for the user to re-trigger. 0 = retry forever (old behavior).
    "maxConnectAttempts": "integer(default=5, min=0, max=100)",
}


def _is_nvda_modifier(vkCode, extended):
    """Whether the given VK is something NVDA might be using as its modifier.

    We accept both Insert and CapsLock unconditionally — covers the
    overwhelming majority of NVDA configurations. Users with a custom modifier
    setup can rebind the toggle gesture themselves.
    """
    return vkCode in (VK_CAPITAL, VK_INSERT)


def _nvda_modifier_currently_held():
    """True if NVDA's modifier-tracker shows Insert or CapsLock as held.

    Used to recognize the `NVDA+f11` toggle while passthrough is active —
    plain F11 should be forwarded, NVDA+F11 should fire the local script.
    """
    try:
        for key in keyboardHandler.currentModifiers:
            # currentModifiers may be a set of (vk, extended) tuples or a dict
            # keyed by them, depending on NVDA version. Either way iteration
            # yields the tuple.
            vk = key[0] if isinstance(key, tuple) else key
            if vk in (VK_CAPITAL, VK_INSERT):
                return True
    except Exception:
        # Defensive: if NVDA's internal shape changed, fall back to "no" so
        # the toggle still works via the explicit F11 unconditional path
        # (which falls through to the original handler regardless).
        pass
    return False


class NvdrBridge:
    """Lifecycle wrapper around the nvdr subprocess and its IPC streams."""

    def __init__(self):
        self.proc = None
        self.passthrough = False
        self.connected = False
        # Set when the user presses NVDA+F11 to connect: once the channel is
        # joined (`state ready`) we flip passthrough on automatically and
        # announce it, so a single press both connects and starts forwarding.
        # Honored (and cleared) on `ready`; survives the IPC layer's own
        # connect retries so a slow first connect still ends up forwarding.
        self.pending_passthrough = False
        # Last reason text we can put on a "couldn't connect" announcement:
        # last_error is the IPC layer's `error …` line (relay-side cause),
        # last_stderr is the most recent ssh/nvdr stderr line (covers ssh auth
        # failures, which never produce an `error` event). Reset per attempt.
        self.last_error = ""
        self.last_stderr = ""
        # One-shot guard so the IPC layer's backoff retries don't repeat the
        # failure announcement. Reset at the start of each connect attempt.
        self.connect_failed_announced = False
        # Retry bounding. The IPC layer reconnects forever on its own; we count
        # consecutive `state disconnected` events and tear the process down once
        # we hit max_attempts (snapshotted from config per attempt; 0 = forever),
        # so it doesn't hammer the relay indefinitely. failed_attempts resets to
        # 0 on every successful join. _giving_up guards the teardown as one-shot.
        self.failed_attempts = 0
        self.max_attempts = 0
        self._giving_up = False
        # True only while stop() is deliberately tearing the process down, so
        # the stdout EOF handler stays silent for an intentional shutdown.
        self._stopping = False
        self._stdout_thread = None
        self._stderr_thread = None
        self._write_lock = threading.Lock()

    # -- subprocess management ------------------------------------------------

    def start(self):
        cfg = config.conf["nvdrBridge"]
        if not cfg["sshHost"] or not cfg["channel"]:
            log.warning(
                "nvdrBridge: ssh host or channel not configured; not starting"
            )
            return

        # Fresh attempt: clear reason text and re-arm the one-shot failure
        # announcement so this connect can report its own outcome.
        self.last_error = ""
        self.last_stderr = ""
        self.connect_failed_announced = False
        self._stopping = False
        # Re-arm retry bounding and snapshot the cap (read on the main thread
        # here; the stdout thread later compares against this cached value).
        self.failed_attempts = 0
        self._giving_up = False
        self.max_attempts = cfg["maxConnectAttempts"]

        # Build the command nvdr will run on the bridge box. shlex.quote on
        # each piece so a channel key with shell metacharacters can't break
        # out of the remote command.
        remote_argv = [
            cfg["remoteNvdrCommand"].strip() or "nvdr",
            "--ipc",
            "--host", cfg["relayHost"],
            "--port", str(cfg["relayPort"]),
            "--channel", cfg["channel"],
        ]
        if cfg["fingerprint"]:
            remote_argv += ["--fingerprint", cfg["fingerprint"]]
        if cfg["insecure"]:
            remote_argv += ["--insecure"]
        remote_cmd = " ".join(shlex.quote(a) for a in remote_argv)

        # SSH args. `-T` disables pty allocation (we want clean binary stdio);
        # BatchMode=yes forces key-based auth — NVDA can't service an
        # interactive password prompt. The user can add `-i /path/to/key` or
        # similar via the Extra args field.
        ssh = cfg["sshCommand"].strip() or "ssh"
        target = (
            f"{cfg['sshUser']}@{cfg['sshHost']}" if cfg["sshUser"]
            else cfg["sshHost"]
        )
        ssh_argv = [
            ssh, "-T",
            "-p", str(cfg["sshPort"]),
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
        ]
        if cfg["sshExtraArgs"].strip():
            ssh_argv += shlex.split(cfg["sshExtraArgs"])
        ssh_argv += [target, remote_cmd]

        creationflags = _CREATE_NO_WINDOW if sys.platform == "win32" else 0
        try:
            self.proc = subprocess.Popen(
                ssh_argv,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                creationflags=creationflags,
                bufsize=0,
            )
        except FileNotFoundError as e:
            log.error(
                f"nvdrBridge: cannot find ssh {ssh!r}: {e}. "
                "Set the SSH command in NVDA Settings → nvdr Bridge."
            )
            self.proc = None
            return
        except Exception as e:
            log.exception(f"nvdrBridge: failed to start ssh: {e}")
            self.proc = None
            return
        self._stdout_thread = threading.Thread(
            target=self._stdout_loop, name="nvdrBridge-stdout", daemon=True,
        )
        self._stdout_thread.start()
        self._stderr_thread = threading.Thread(
            target=self._stderr_loop, name="nvdrBridge-stderr", daemon=True,
        )
        self._stderr_thread.start()
        log.info(
            f"nvdrBridge: spawned ssh -> {target}:{cfg['sshPort']} pid={self.proc.pid}"
        )

    def stop(self):
        if self.proc is None:
            return
        # Mark the teardown as intentional so the stdout EOF handler doesn't
        # mistake this clean shutdown for a connect failure / dropped session.
        self._stopping = True
        try:
            self._write_line("quit")
        except Exception:
            pass
        try:
            self.proc.wait(timeout=2)
        except Exception:
            try:
                self.proc.terminate()
            except Exception:
                log.exception("nvdrBridge: terminate failed")
        self.proc = None
        self.connected = False
        # A deliberate teardown clears forwarding + any pending intent so a
        # later (re)start doesn't resume sending keys without a fresh press.
        self.passthrough = False
        self.pending_passthrough = False

    def restart(self):
        self.stop()
        self.start()

    def ensure_started(self):
        """Start the bridge if it isn't already running.

        Connection is lazy (triggered by NVDA+F11), so this is the entry
        point that brings the subprocess up. Returns one of:
          "unconfigured" — ssh host / channel not set; nothing started.
          "running"      — a process is already alive (connecting or up).
          "started"      — a fresh process was (re)spawned.
        """
        cfg = config.conf["nvdrBridge"]
        if not cfg["sshHost"] or not cfg["channel"]:
            return "unconfigured"
        proc = self.proc
        if proc is not None and proc.poll() is None:
            return "running"
        # No process, or a dead one whose stdout loop already flipped us to
        # disconnected — clear it out and spawn fresh.
        if proc is not None:
            self.stop()
        self.start()
        return "started"

    # -- I/O loops ------------------------------------------------------------

    def _stdout_loop(self):
        proc = self.proc
        if proc is None or proc.stdout is None:
            return
        try:
            for raw in proc.stdout:
                try:
                    line = raw.decode("utf-8", "replace").rstrip("\r\n")
                except Exception:
                    continue
                self._handle_event(line)
        except Exception:
            log.exception("nvdrBridge: stdout loop crashed")
        log.info("nvdrBridge: stdout loop exited")
        # The subprocess closed its output, i.e. it exited (ssh/auth failure,
        # missing remote command, or nvdr hit a fatal error). Mark disconnected
        # so the next toggle attempt warns rather than silently dropping keys.
        self.connected = False
        if self._stopping:
            # Intentional teardown — say nothing.
            pass
        elif self.pending_passthrough:
            # A connect the user asked for never reached `ready`.
            self._announce_connect_failure(self.last_error or self.last_stderr)
        elif self.passthrough:
            # We were forwarding and the bridge died under us.
            self.passthrough = False
            wx.CallAfter(ui.message, _("nvdr disconnected; key forwarding off"))

    def _stderr_loop(self):
        proc = self.proc
        if proc is None or proc.stderr is None:
            return
        try:
            for raw in proc.stderr:
                try:
                    text = raw.decode("utf-8", "replace").rstrip()
                except Exception:
                    continue
                log.info("nvdr: " + text)
                # Keep the last non-empty stderr line as a fallback reason for
                # a "couldn't connect" announcement — ssh auth failures
                # ("Permission denied …") surface here and nowhere else.
                if text:
                    self.last_stderr = text
        except Exception:
            log.exception("nvdrBridge: stderr loop crashed")

    def _announce_connect_failure(self, reason):
        """Announce a failed connect attempt once, with a reason if we have one.

        Guarded by `connect_failed_announced` so the IPC layer's backoff
        retries (each ending in another `state disconnected`) don't repeat the
        message. Deliberately does NOT clear `pending_passthrough`: if a later
        retry succeeds we still want that connect to start forwarding.
        """
        if self.connect_failed_announced:
            return
        self.connect_failed_announced = True
        reason = (reason or "").strip()
        # The IPC layer prefixes relay connect errors with "connect: " — drop
        # it so we don't speak "couldn't connect: connect: …".
        if reason.startswith("connect: "):
            reason = reason[len("connect: "):]
        log.warning(f"nvdrBridge: connect failed: {reason!r}")
        if reason:
            # Translators: spoken when the bridge can't connect; {reason} is the
            # underlying ssh / relay error text.
            msg = _("nvdr couldn't connect: {reason}").format(reason=reason)
        else:
            # Translators: spoken when the bridge can't connect, cause unknown
            msg = _("nvdr couldn't connect")
        wx.CallAfter(ui.message, msg)

    def _give_up(self):
        """Stop retrying after too many failed attempts and tell the user.

        The IPC layer would otherwise reconnect forever (backoff capped at
        30s). We tear the subprocess down so it stops hammering the relay, and
        clear pending intent so the next NVDA+F11 starts a clean attempt. The
        actual stop() runs on a worker thread because, mid connect-retry, the
        process isn't reading stdin and stop() falls back to a ~2s terminate —
        we don't want that blocking NVDA's main thread.
        """
        if self._giving_up:
            return
        self._giving_up = True
        self.pending_passthrough = False
        log.warning(
            f"nvdrBridge: giving up after {self.failed_attempts} failed attempt(s)"
        )
        # Translators: spoken when the bridge stops retrying after repeated
        # connection failures
        wx.CallAfter(ui.message, _("nvdr stopped trying to connect"))
        threading.Thread(
            target=self.stop, name="nvdrBridge-giveup", daemon=True,
        ).start()

    def _handle_event(self, line):
        if not line:
            return
        head, _sep, rest = line.partition(" ")
        if head == "speak":
            # speech.speakMessage routes through NVDA's synth — wx.CallAfter
            # to land on the main thread.
            wx.CallAfter(speech.speakMessage, rest)
        elif head == "cancel":
            wx.CallAfter(speech.cancelSpeech)
        elif head == "state":
            self._handle_state(rest)
        elif head == "error":
            # Remember it as the likely reason for a subsequent failure
            # announcement (the `error` line precedes `state disconnected`).
            self.last_error = rest
            log.warning(f"nvdr error: {rest}")
        else:
            log.debug(f"nvdrBridge: unknown event line: {line!r}")

    def _handle_state(self, name):
        if name == "ready":
            self.connected = True
            # A good join clears the failure budget so later reconnects get a
            # fresh allowance rather than inheriting earlier failures.
            self.failed_attempts = 0
            log.info("nvdrBridge: ready (channel joined)")
            if self.pending_passthrough:
                # The user pressed NVDA+F11 to connect — honor that by turning
                # forwarding on now and announcing both facts in one message.
                self.pending_passthrough = False
                self.passthrough = True
                wx.CallAfter(
                    # Translators: spoken once the relay connects and key
                    # forwarding turns on automatically
                    ui.message, _("nvdr connected, sending keys to remote")
                )
            else:
                # A reconnect we didn't explicitly ask to forward on (e.g. the
                # IPC layer recovered after a drop). Report it, leave
                # forwarding off so keys don't silently start going remote.
                # Translators: spoken when the relay (re)connects
                wx.CallAfter(ui.message, _("nvdr connected"))
        elif name == "disconnected":
            self.connected = False
            if self._giving_up:
                # Already tearing down — ignore the retry storm until the
                # process is gone, so we don't double-count or double-announce.
                return
            self.failed_attempts += 1
            if self.pending_passthrough:
                # A connect the user asked for failed before joining. Announce
                # once (with the reason); the IPC layer keeps retrying, and we
                # leave pending_passthrough set so an eventual success forwards.
                self._announce_connect_failure(self.last_error or self.last_stderr)
            elif self.passthrough:
                # Mid-session drop while forwarding — stop forwarding, say so.
                self.passthrough = False
                wx.CallAfter(ui.message, _("nvdr disconnected; key forwarding off"))
            if self.max_attempts and self.failed_attempts >= self.max_attempts:
                # Hit the cap — stop the endless reconnect loop.
                self._give_up()
        elif name == "nvda_not_connected":
            log.info("nvdrBridge: relay reports no remote NVDA on the channel")
        elif name == "quit":
            self.connected = False
            self.pending_passthrough = False

    # -- writing commands -----------------------------------------------------

    def _write_line(self, s):
        proc = self.proc
        if proc is None or proc.stdin is None:
            log.warning(
                f"nvdrBridge: _write_line dropped (no proc/stdin) line={s!r}"
            )
            return
        with self._write_lock:
            try:
                proc.stdin.write((s + "\n").encode("utf-8"))
                proc.stdin.flush()
                log.debug(f"nvdrBridge: wrote {s!r}")
            except (BrokenPipeError, OSError) as e:
                log.warning(f"nvdrBridge: write failed: {e}")

    def forward_key(self, vkCode, pressed):
        log.info(
            f"nvdrBridge: forward_key vk={vkCode} pressed={pressed} "
            f"connected={self.connected} passthrough={self.passthrough}"
        )
        self._write_line("key {} {}".format(vkCode, 1 if pressed else 0))

    def release_all(self):
        self._write_line("release_all")


# Module-level state so the patched keyboardHandler hooks can find the bridge
# without going through GlobalPlugin (which itself owns the reference).
_bridge = None
_orig_keyDown = None
_orig_keyUp = None

# VK codes for NVDA modifier keys we've seen pressed *while passthrough is on*.
# We track this ourselves rather than reading NVDA's currentModifiers because
# in passthrough mode the hook never forwards modifier events to NVDA (doing so
# would trigger NVDA's own "modifier alone" gestures locally, and worse, fail
# to forward the modifier to the remote so chords like NVDA+T arrive there
# stripped of their modifier). We need the modifier on the *remote*; we only
# need its held-state *locally* to detect the NVDA+F11 toggle-off gesture.
_passthrough_mods_held = set()


def _hook_keyDown(vkCode, scanCode, extended, injected):
    """Replacement for keyboardHandler.internal_keyDownEvent.

    Invoked by NVDA's low-level hook. In passthrough mode we forward keys to
    the remote nvdr; otherwise we delegate to NVDA's original handler so NVDA
    continues to behave normally (including its normal NVDA+F11 toggle-on
    gesture binding).
    """
    try:
        if _bridge is not None and _bridge.passthrough:
            log.info(
                f"nvdrBridge: hook_keyDown vk={vkCode} ext={extended} "
                f"inj={injected} connected={_bridge.connected}"
            )
    except Exception:
        log.exception("nvdrBridge: hook_keyDown logging failed")
    if (
        _bridge is None
        or _orig_keyDown is None
        or injected
        or not _bridge.passthrough
        or not _bridge.connected
    ):
        return _orig_keyDown(vkCode, scanCode, extended, injected) if _orig_keyDown else True

    # NVDA+F11 = toggle gesture. We can't rely on NVDA's script dispatch here
    # because in passthrough mode we never let NVDA see the modifier press —
    # so handle the chord ourselves.
    if vkCode == VK_F11 and _passthrough_mods_held:
        _toggle_passthrough_off()
        return False

    if _is_nvda_modifier(vkCode, extended):
        _passthrough_mods_held.add(vkCode)
        _bridge.forward_key(vkCode, True)
        return False

    _bridge.forward_key(vkCode, True)
    return False


def _hook_keyUp(vkCode, scanCode, extended, injected):
    try:
        if _bridge is not None and _bridge.passthrough:
            log.info(
                f"nvdrBridge: hook_keyUp vk={vkCode} ext={extended} "
                f"inj={injected} connected={_bridge.connected}"
            )
    except Exception:
        log.exception("nvdrBridge: hook_keyUp logging failed")
    if (
        _bridge is None
        or _orig_keyUp is None
        or injected
        or not _bridge.passthrough
        or not _bridge.connected
    ):
        return _orig_keyUp(vkCode, scanCode, extended, injected) if _orig_keyUp else True

    # Swallow the F11-up that pairs with a toggle-off chord we already
    # consumed. Without this NVDA would see a stray F11-up.
    if vkCode == VK_F11:
        return False

    if _is_nvda_modifier(vkCode, extended):
        _passthrough_mods_held.discard(vkCode)
        _bridge.forward_key(vkCode, False)
        return False

    _bridge.forward_key(vkCode, False)
    return False


def _toggle_passthrough_off():
    """Handle NVDA+F11 *inside* passthrough mode (hook-thread context).

    NVDA's normal script-binding for NVDA+F11 only fires when NVDA's own
    `currentModifiers` has the NVDA key — but in passthrough mode we don't
    feed modifier events to NVDA, so that path never fires the script. Do the
    same work ourselves: drop passthrough, release any keys we've left held on
    the remote, and announce locally.
    """
    if _bridge is None:
        return
    _bridge.passthrough = False
    _passthrough_mods_held.clear()
    _bridge.release_all()
    log.info("nvdrBridge: passthrough toggled -> False (via in-hook NVDA+F11)")
    wx.CallAfter(ui.message, _("Sending keys locally"))


class GlobalPlugin(globalPluginHandler.GlobalPlugin):
    # Translators: input gesture category for this add-on
    scriptCategory = _("nvdr Bridge")

    def __init__(self):
        super().__init__()
        global _bridge, _orig_keyDown, _orig_keyUp
        config.conf.spec["nvdrBridge"] = confspec
        NVDASettingsDialog.categoryClasses.append(NvdrBridgeSettings)

        _bridge = NvdrBridge()
        # Do NOT start the subprocess here — connection is lazy. The first
        # NVDA+F11 press (script_toggleSend) brings the bridge up on demand.

        # Install keyboard hooks. NVDA captures the callbacks at startup via
        # `winInputHook.setCallbacks(keyDown=internal_keyDownEvent, …)`, so
        # reassigning `keyboardHandler.internal_keyDownEvent` does NOT change
        # what the low-level hook actually invokes — winInputHook is still
        # holding the original function reference. We have to register our
        # wrappers into winInputHook directly. We also still patch the module
        # attribute as a belt-and-braces measure for older NVDA builds.
        _orig_keyDown = keyboardHandler.internal_keyDownEvent
        _orig_keyUp = keyboardHandler.internal_keyUpEvent
        keyboardHandler.internal_keyDownEvent = _hook_keyDown
        keyboardHandler.internal_keyUpEvent = _hook_keyUp
        if winInputHook is not None:
            try:
                winInputHook.setCallbacks(
                    keyDown=_hook_keyDown, keyUp=_hook_keyUp,
                )
                log.info("nvdrBridge: winInputHook callbacks installed")
            except Exception:
                log.exception("nvdrBridge: winInputHook.setCallbacks failed")
        else:
            log.warning(
                "nvdrBridge: winInputHook not importable; hooks may not fire"
            )

    def terminate(self):
        global _bridge, _orig_keyDown, _orig_keyUp
        try:
            if _orig_keyDown is not None:
                keyboardHandler.internal_keyDownEvent = _orig_keyDown
            if _orig_keyUp is not None:
                keyboardHandler.internal_keyUpEvent = _orig_keyUp
            if winInputHook is not None and _orig_keyDown is not None:
                try:
                    winInputHook.setCallbacks(
                        keyDown=_orig_keyDown, keyUp=_orig_keyUp,
                    )
                except Exception:
                    log.exception(
                        "nvdrBridge: restoring winInputHook callbacks failed"
                    )
        except Exception:
            log.exception("nvdrBridge: restoring keyboard hooks failed")
        _orig_keyDown = None
        _orig_keyUp = None
        try:
            NVDASettingsDialog.categoryClasses.remove(NvdrBridgeSettings)
        except ValueError:
            pass
        if _bridge is not None:
            _bridge.stop()
            _bridge = None

    @scriptHandler.script(
        # Translators: input gesture description
        description=_("Connect to, or toggle sending keys to, the remote NVDA"),
        gesture="kb:NVDA+f11",
    )
    def script_toggleSend(self, gesture):
        if _bridge is None:
            # Translators: spoken when no bridge is running
            ui.message(_("nvdr bridge not started"))
            return
        if not _bridge.connected:
            # Not connected yet: this press initiates the connection rather
            # than toggling passthrough. We connect on demand instead of at
            # NVDA startup so the SSH/relay session only exists when wanted.
            status = _bridge.ensure_started()
            if status == "unconfigured":
                # Translators: spoken when ssh host / channel aren't configured
                ui.message(_("nvdr bridge not configured"))
            else:
                # Remember the user wants to forward; _handle_state turns
                # passthrough on (and announces) the moment the channel joins.
                _bridge.pending_passthrough = True
                # Translators: spoken while the bridge connects to the relay
                ui.message(_("nvdr connecting"))
            return
        _bridge.passthrough = not _bridge.passthrough
        log.info(
            f"nvdrBridge: passthrough toggled -> {_bridge.passthrough} "
            f"(connected={_bridge.connected})"
        )
        if not _bridge.passthrough:
            # Drop any modifiers we sent over before flipping off so the
            # remote slave doesn't keep them latched.
            _bridge.release_all()
        ui.message(
            # Translators: spoken when key forwarding is enabled
            _("Sending keys to remote") if _bridge.passthrough
            # Translators: spoken when key forwarding is disabled
            else _("Sending keys locally")
        )

    @scriptHandler.script(
        # Translators: input gesture description
        description=_("Restart the nvdr bridge process"),
    )
    def script_restartBridge(self, gesture):
        if _bridge is None:
            return
        # Translators: spoken when the bridge is being restarted
        ui.message(_("nvdr bridge restarting"))
        wx.CallAfter(_bridge.restart)


class NvdrBridgeSettings(SettingsPanel):
    # Translators: title of the settings panel
    title = _("nvdr Bridge")

    def makeSettings(self, settingsSizer):
        sHelper = guiHelper.BoxSizerHelper(self, sizer=settingsSizer)
        cfg = config.conf["nvdrBridge"]

        # -- SSH bridge group ----------------------------------------------
        sshSizer = wx.StaticBoxSizer(
            wx.VERTICAL, self,
            # Translators: settings group label
            label=_("SSH bridge (where nvdr runs)"),
        )
        sshBox = sshSizer.GetStaticBox()
        sshHelper = guiHelper.BoxSizerHelper(self, sizer=sshSizer)

        # Translators: settings field
        self.sshHostEdit = sshHelper.addLabeledControl(
            _("Bridge &host (SSH):"), wx.TextCtrl,
        )
        self.sshHostEdit.SetValue(cfg["sshHost"])

        # Translators: settings field
        self.sshPortSpin = sshHelper.addLabeledControl(
            _("SSH &port:"),
            nvdaControls.SelectOnFocusSpinCtrl,
            min=1, max=65535,
        )
        self.sshPortSpin.SetValue(cfg["sshPort"])

        # Translators: settings field
        self.sshUserEdit = sshHelper.addLabeledControl(
            _("SSH &user:"), wx.TextCtrl,
        )
        self.sshUserEdit.SetValue(cfg["sshUser"])

        # Translators: settings field
        self.sshCommandEdit = sshHelper.addLabeledControl(
            _("SSH &command (full path or just 'ssh'):"), wx.TextCtrl,
        )
        self.sshCommandEdit.SetValue(cfg["sshCommand"])

        # Translators: settings field
        self.sshExtraEdit = sshHelper.addLabeledControl(
            _("Extra SSH &args (e.g. -i C:\\path\\to\\key):"), wx.TextCtrl,
        )
        self.sshExtraEdit.SetValue(cfg["sshExtraArgs"])

        # Translators: settings field
        self.remoteNvdrEdit = sshHelper.addLabeledControl(
            _("Remote &nvdr command (path on the bridge box):"), wx.TextCtrl,
        )
        self.remoteNvdrEdit.SetValue(cfg["remoteNvdrCommand"])

        sHelper.addItem(sshSizer)

        # -- Relay group ---------------------------------------------------
        relaySizer = wx.StaticBoxSizer(
            wx.VERTICAL, self,
            # Translators: settings group label
            label=_("NVDA Remote relay (what nvdr dials out to)"),
        )
        relayBox = relaySizer.GetStaticBox()
        relayHelper = guiHelper.BoxSizerHelper(self, sizer=relaySizer)

        # Translators: settings field
        self.relayHostEdit = relayHelper.addLabeledControl(
            _("&Relay host:"), wx.TextCtrl,
        )
        self.relayHostEdit.SetValue(cfg["relayHost"])

        # Translators: settings field
        self.relayPortSpin = relayHelper.addLabeledControl(
            _("R&elay port:"),
            nvdaControls.SelectOnFocusSpinCtrl,
            min=1, max=65535,
        )
        self.relayPortSpin.SetValue(cfg["relayPort"])

        # Translators: settings field
        self.channelEdit = relayHelper.addLabeledControl(
            _("&Channel key:"), wx.TextCtrl,
        )
        self.channelEdit.SetValue(cfg["channel"])

        # Translators: settings field
        self.fingerprintEdit = relayHelper.addLabeledControl(
            _("Pinned cert &fingerprint (sha-256 hex, blank = TOFU):"),
            wx.TextCtrl,
        )
        self.fingerprintEdit.SetValue(cfg["fingerprint"])

        # Translators: settings field
        self.insecureCheck = relayHelper.addItem(
            wx.CheckBox(self, label=_("&Insecure: skip TLS verification (testing only)"))
        )
        self.insecureCheck.SetValue(cfg["insecure"])

        # Translators: settings field. 0 means keep retrying forever.
        self.maxAttemptsSpin = relayHelper.addLabeledControl(
            _("Connection &attempts before giving up (0 = keep trying):"),
            nvdaControls.SelectOnFocusSpinCtrl,
            min=0, max=100,
        )
        self.maxAttemptsSpin.SetValue(cfg["maxConnectAttempts"])

        sHelper.addItem(relaySizer)

    def onSave(self):
        cfg = config.conf["nvdrBridge"]
        cfg["sshHost"] = self.sshHostEdit.GetValue()
        cfg["sshPort"] = self.sshPortSpin.GetValue()
        cfg["sshUser"] = self.sshUserEdit.GetValue()
        cfg["sshCommand"] = self.sshCommandEdit.GetValue()
        cfg["sshExtraArgs"] = self.sshExtraEdit.GetValue()
        cfg["remoteNvdrCommand"] = self.remoteNvdrEdit.GetValue()
        cfg["relayHost"] = self.relayHostEdit.GetValue()
        cfg["relayPort"] = self.relayPortSpin.GetValue()
        cfg["channel"] = self.channelEdit.GetValue()
        cfg["fingerprint"] = self.fingerprintEdit.GetValue()
        cfg["insecure"] = self.insecureCheck.GetValue()
        cfg["maxConnectAttempts"] = self.maxAttemptsSpin.GetValue()
        # Apply the new connection params immediately rather than making the
        # user restart NVDA to see the change take effect — but only if a
        # session is already up. Connection is lazy (NVDA+F11), so saving
        # settings must not itself bring the bridge online.
        if _bridge is not None and _bridge.proc is not None:
            wx.CallAfter(_bridge.restart)
