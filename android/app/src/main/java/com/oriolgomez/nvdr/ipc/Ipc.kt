package com.oriolgomez.nvdr.ipc

/**
 * Wire format spoken by `nvdr --ipc`. The Rust side is `src/ipc.rs`; this is a
 * faithful port of the iOS/macOS `IPC.swift`. Plain ASCII, line-oriented, one
 * event per line.
 *
 * We send: `key <vk> <0|1>`, `combo <spec>`, `type <text>`, `sas`,
 * `release_all`, `quit`. We receive: `speak <text>`, `cancel`, `state <name>`,
 * `error <message>`. Anything else on stdout is logged and dropped.
 */
sealed interface IpcEvent {
    data class Speak(val text: String) : IpcEvent
    data object Cancel : IpcEvent
    data class State(val state: BridgeState) : IpcEvent
    data class Error(val message: String) : IpcEvent
    data class Unknown(val raw: String) : IpcEvent
}

enum class BridgeState(val wire: String) {
    Connecting("connecting"),
    Ready("ready"),
    NvdaNotConnected("nvda_not_connected"),
    Disconnected("disconnected"),
    Quit("quit"),
    Unknown("unknown");

    companion object {
        fun from(wire: String): BridgeState =
            entries.firstOrNull { it.wire == wire } ?: Unknown
    }
}

sealed interface IpcCommand {
    /** Raw VK transition. [pressed] is the down (true) / up (false) flag. */
    data class Key(val vk: Int, val pressed: Boolean) : IpcCommand
    data class Combo(val spec: String) : IpcCommand
    data class Type(val text: String) : IpcCommand
    data object Sas : IpcCommand
    data object ReleaseAll : IpcCommand
    data object Quit : IpcCommand

    /** The exact bytes (sans trailing newline) we write to the bridge's stdin. */
    fun line(): String = when (this) {
        is Key -> "key $vk ${if (pressed) 1 else 0}"
        is Combo -> "combo $spec"
        is Type -> "type ${escape(text)}"
        Sas -> "sas"
        ReleaseAll -> "release_all"
        Quit -> "quit"
    }

    companion object {
        /** Mirror of the `unescape` in `src/ipc.rs` (`\n`, `\r`, `\t`, `\\`). */
        private fun escape(s: String): String {
            val out = StringBuilder(s.length)
            for (ch in s) {
                when (ch) {
                    '\\' -> out.append("\\\\")
                    '\n' -> out.append("\\n")
                    '\r' -> out.append("\\r")
                    '\t' -> out.append("\\t")
                    else -> out.append(ch)
                }
            }
            return out.toString()
        }
    }
}

object IpcParser {
    /** Parse one stdout line from `nvdr --ipc` into an [IpcEvent]. */
    fun parse(raw: String): IpcEvent {
        val line = raw.trimEnd('\r', '\n')
        if (line.isEmpty()) return IpcEvent.Unknown("")
        val space = line.indexOf(' ')
        val head = if (space < 0) line else line.substring(0, space)
        val rest = if (space < 0) "" else line.substring(space + 1)
        return when (head) {
            "speak" -> IpcEvent.Speak(rest)
            "cancel" -> IpcEvent.Cancel
            "state" -> IpcEvent.State(BridgeState.from(rest))
            "error" -> IpcEvent.Error(rest)
            else -> IpcEvent.Unknown(line)
        }
    }
}
