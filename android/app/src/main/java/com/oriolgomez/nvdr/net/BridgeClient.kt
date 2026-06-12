package com.oriolgomez.nvdr.net

import android.util.Log
import com.oriolgomez.nvdr.ipc.BridgeState
import com.oriolgomez.nvdr.ipc.IpcCommand
import com.oriolgomez.nvdr.ipc.IpcEvent
import com.oriolgomez.nvdr.ipc.IpcParser
import com.oriolgomez.nvdr.settings.BridgeConfig
import com.oriolgomez.nvdr.settings.SSHAuthMode
import com.oriolgomez.nvdr.speech.SpeechOutput
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.coroutines.coroutineContext
import net.schmizz.sshj.DefaultConfig
import net.schmizz.sshj.SSHClient
import net.schmizz.keepalive.KeepAliveProvider
import net.schmizz.sshj.transport.verification.PromiscuousVerifier
import net.schmizz.sshj.userauth.password.PasswordUtils

/**
 * Drives the whole SSH → `nvdr --ipc` → speech pipeline, mirroring the iOS/macOS
 * `BridgeClient`. Opens an SSH exec channel to the bridge host, runs the line
 * protocol from `src/ipc.rs`, routes `speak` to [SpeechOutput], and pushes
 * keystrokes back as `key <vk> <0|1>`.
 *
 * The SSH connection auto-reconnects with exponential backoff (500 ms → 30 s),
 * matching nvdr's own relay reconnect loop. Note that nvdr keeps running and
 * retries the *relay* on its own, surfacing `state disconnected` / `state ready`
 * over stdout — those are informational and never tear down the SSH session.
 */
class BridgeClient(
    private val speech: SpeechOutput,
    private val scope: CoroutineScope,
) {
    sealed interface Status {
        data object Idle : Status
        data object Connecting : Status
        data object Authenticating : Status
        data object Ready : Status
        data object NvdaNotConnected : Status
        data class Disconnected(val reason: String) : Status
        data class Failed(val message: String) : Status
    }

    private val _status = MutableStateFlow<Status>(Status.Idle)
    val status: StateFlow<Status> = _status.asStateFlow()

    private val _lastSpeech = MutableStateFlow("")
    val lastSpeech: StateFlow<String> = _lastSpeech.asStateFlow()

    private val _log = MutableStateFlow<List<String>>(emptyList())
    val log: StateFlow<List<String>> = _log.asStateFlow()

    private val _forwarding = MutableStateFlow(false)
    val forwarding: StateFlow<Boolean> = _forwarding.asStateFlow()

    @Volatile
    private var writer: SendChannel<IpcCommand>? = null

    /** The live SSH client, so [stop] can force-close it to unblock a reader. */
    @Volatile
    private var activeSsh: SSHClient? = null
    private var job: Job? = null

    val isRunning: Boolean get() = job?.isActive == true

    fun start(config: BridgeConfig) {
        if (isRunning) return
        _lastSpeech.value = ""
        job = scope.launch(Dispatchers.IO) { runLoop(config) }
    }

    fun stop() {
        writer?.trySend(IpcCommand.Quit)
        // Force-close the socket so a reader blocked in readLine() returns at once.
        runCatching { activeSsh?.disconnect() }
        job?.cancel(CancellationException("user stop"))
        job = null
        writer = null
        activeSsh = null
        _forwarding.value = false
        _status.value = Status.Idle
    }

    fun setForwarding(on: Boolean) {
        if (_forwarding.value == on) return
        _forwarding.value = on
        if (!on) send(IpcCommand.ReleaseAll)
        speech.announce(if (on) "Forwarding on" else "Forwarding off")
    }

    fun send(command: IpcCommand) {
        // Silently dropped when no session is up, matching the add-on's behavior.
        writer?.trySend(command)
    }

    fun sendKey(vk: Int, pressed: Boolean) = send(IpcCommand.Key(vk, pressed))

    fun clearLog() { _log.value = emptyList() }

    private suspend fun runLoop(config: BridgeConfig) {
        var backoffMs = 500L
        while (coroutineContext.isActive) {
            _status.value = Status.Connecting
            appendLog("connecting ssh ${config.sshHost}:${config.sshPort}…")

            val cfg = DefaultConfig().apply { keepAliveProvider = KeepAliveProvider.HEARTBEAT }
            val ssh = SSHClient(cfg)
            activeSsh = ssh
            try {
                ssh.addHostKeyVerifier(PromiscuousVerifier()) // TOFU: nvdr itself pins the relay cert
                ssh.connectTimeout = 15_000
                ssh.connect(config.sshHost, config.sshPort)
                ssh.connection.keepAlive.keepAliveInterval = 20
                appendLog("server: ${runCatching { ssh.transport.serverVersion }.getOrNull()}")
                authenticate(ssh, config)

                _status.value = Status.Authenticating
                appendLog("ssh authenticated; spawning: ${config.remoteCommand}")
                backoffMs = 500L

                runSession(ssh, config)

                if (!coroutineContext.isActive) break
                _status.value = Status.Disconnected("ssh closed")
                appendLog("ssh session ended")
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                if (!coroutineContext.isActive) break // user stop force-closed the socket
                val msg = e.message ?: e.javaClass.simpleName
                appendLog("ssh error: ${e.javaClass.simpleName}: $msg")
                var cause = e.cause
                while (cause != null) {
                    appendLog("  caused by: ${cause.javaClass.simpleName}: ${cause.message}")
                    cause = cause.cause
                }
                _status.value = Status.Failed(msg)
            } finally {
                writer = null
                if (activeSsh === ssh) activeSsh = null
                runCatching { ssh.disconnect() }
            }

            if (!coroutineContext.isActive) break
            delay(backoffMs)
            backoffMs = (backoffMs * 2).coerceAtMost(30_000L)
        }
    }

    private fun authenticate(ssh: SSHClient, config: BridgeConfig) {
        when (config.authMode) {
            SSHAuthMode.Password -> ssh.authPassword(config.sshUser, config.password)
            SSHAuthMode.PrivateKey -> {
                val keys = if (config.privateKeyPassphrase.isNotEmpty()) {
                    ssh.loadKeys(
                        config.privateKeyPem,
                        null,
                        PasswordUtils.createOneOff(config.privateKeyPassphrase.toCharArray()),
                    )
                } else {
                    ssh.loadKeys(config.privateKeyPem, null, null)
                }
                ssh.authPublickey(config.sshUser, keys)
            }
        }
    }

    private suspend fun runSession(ssh: SSHClient, config: BridgeConfig) {
        val session = ssh.startSession()
        try {
            val cmd = session.exec(config.remoteCommand)
            val wch = Channel<IpcCommand>(Channel.UNLIMITED)
            writer = wch

            coroutineScope {
                // Writer: drain queued commands to the remote's stdin.
                val writeJob = launch(Dispatchers.IO) {
                    val os = cmd.outputStream
                    try {
                        for (c in wch) {
                            os.write((c.line() + "\n").toByteArray(Charsets.UTF_8))
                            os.flush()
                        }
                    } catch (_: CancellationException) {
                        // expected on teardown
                    } catch (e: Exception) {
                        appendLog("write: ${e.message}")
                    }
                }

                // Stderr drain → log (nvdr tees diagnostics here).
                val errJob = launch(Dispatchers.IO) {
                    runCatching {
                        cmd.errorStream.bufferedReader(Charsets.UTF_8).forEachLine { appendLog("nvdr: $it") }
                    }
                }

                // Reader (this coroutine): parse one event per line until EOF.
                val reader = cmd.inputStream.bufferedReader(Charsets.UTF_8)
                while (true) {
                    val line = reader.readLine() ?: break
                    handle(IpcParser.parse(line))
                }

                wch.close()
                writeJob.cancel()
                errJob.cancel()
            }
        } finally {
            writer = null
            runCatching { session.close() }
        }
    }

    private fun handle(event: IpcEvent) {
        when (event) {
            is IpcEvent.Speak -> {
                if (event.text.isNotEmpty()) {
                    _lastSpeech.value = event.text
                    speech.speak(event.text)
                }
            }
            IpcEvent.Cancel -> speech.cancel()
            is IpcEvent.State -> {
                when (event.state) {
                    BridgeState.Connecting -> _status.value = Status.Connecting
                    BridgeState.Ready -> _status.value = Status.Ready
                    BridgeState.NvdaNotConnected -> _status.value = Status.NvdaNotConnected
                    BridgeState.Disconnected -> _status.value = Status.Disconnected("relay")
                    BridgeState.Quit -> appendLog("nvdr quit")
                    BridgeState.Unknown -> appendLog("state ?")
                }
            }
            is IpcEvent.Error -> appendLog("error: ${event.message}")
            is IpcEvent.Unknown -> if (event.raw.isNotEmpty()) appendLog("? ${event.raw}")
        }
    }

    private fun appendLog(line: String) {
        Log.i("nvdr", line)
        _log.value = (_log.value + line).takeLast(MAX_LOG)
    }

    private companion object {
        const val MAX_LOG = 200
    }
}
