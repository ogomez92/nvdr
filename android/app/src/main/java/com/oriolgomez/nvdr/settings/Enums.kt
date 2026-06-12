package com.oriolgomez.nvdr.settings

import com.oriolgomez.nvdr.input.VK

/**
 * Which physical key acts as the NVDA modifier — and, held with F11, toggles
 * keystroke forwarding (mirroring the Windows add-on's NVDA+F11 and the mac
 * port's Caps Lock+F11). On Android we forward the raw physical key either way;
 * this mainly chooses the base of the hardware forwarding-toggle chord.
 */
enum class NvdaModifier(val wire: String, val label: String, val vk: Int) {
    CapsLock("capsLock", "Caps Lock", VK.CAPITAL),
    Insert("insert", "Insert", VK.INSERT);

    companion object {
        fun from(wire: String?) = entries.firstOrNull { it.wire == wire } ?: CapsLock
    }
}

/**
 * What a key with no direct Windows equivalent sends to the slave. A Mac
 * keyboard paired to Android delivers Option as Alt and Command as Meta, so the
 * user picks which Windows modifier each stands in for. Left and right Alt carry
 * independent mappings; Meta applies to both ⌘/Win keys.
 */
enum class ModifierMapping(val wire: String, val label: String) {
    Alt("alt", "Alt"),
    Win("win", "Windows / GUI"),
    Ctrl("ctrl", "Ctrl"),
    None("none", "Ignore");

    companion object {
        fun from(wire: String?, default: ModifierMapping) =
            entries.firstOrNull { it.wire == wire } ?: default
    }
}

/** SSH auth strategy. Many bridge hosts disable password auth entirely. */
enum class SSHAuthMode(val wire: String, val label: String) {
    Password("password", "Password"),
    PrivateKey("privateKey", "Private key");

    companion object {
        fun from(wire: String?) = entries.firstOrNull { it.wire == wire } ?: Password
    }
}
