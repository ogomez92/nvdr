import Foundation
import Observation

/// Which physical key acts as the NVDA modifier on the wire — and, held with
/// F11, toggles keystroke forwarding (mirroring the Windows add-on's NVDA+F11).
///
/// CapsLock is the closest analog to NVDA's default Insert. `KeyCapture` reads
/// it straight off the HID layer (`IOHIDManager`), so it delivers a real
/// down/up per physical press instead of the OS's toggle-only event — the fix
/// for the iOS build's "press it twice" bug. ``voKeys`` (Ctrl+Option, the
/// standard VoiceOver convention) is the alternative for anyone who would
/// rather leave Caps Lock alone.
enum NvdaModifier: String, CaseIterable, Identifiable, Sendable {
    case capsLock
    case voKeys

    var id: String { rawValue }
    var label: String {
        switch self {
        case .capsLock: return "CapsLock"
        case .voKeys: return "VO keys (Ctrl+Option)"
        }
    }
}

/// What a Mac-style modifier key sends to the slave.
///
/// Option (⌥) and Command (⌘) have no Windows equivalent, so the user picks
/// which Windows modifier each stands in for. Left and right Option are
/// configured separately — one keyboard side can cover a different Windows
/// key than the other. Out of the box: Left Option → Windows key, Right
/// Option → Right Ctrl, Command → Alt (applies to both ⌘ keys).
enum ModifierMapping: String, CaseIterable, Identifiable, Sendable {
    case alt
    case win
    case ctrl
    case none

    var id: String { rawValue }
    var label: String {
        switch self {
        case .alt: return "Alt"
        case .win: return "Windows / GUI"
        case .ctrl: return "Ctrl"
        case .none: return "Ignore"
        }
    }
}

/// SSH auth strategy. Many bridge hosts disable password auth entirely, so
/// key auth needs to be a first-class option.
enum SSHAuthMode: String, CaseIterable, Identifiable, Sendable {
    case password
    case privateKey

    var id: String { rawValue }
    var label: String {
        switch self {
        case .password: return "Password"
        case .privateKey: return "Private key"
        }
    }
}

@Observable
@MainActor
final class AppSettings {
    // SSH bridge
    var sshHost: String
    var sshPort: Int
    var sshUser: String
    var sshAuthMode: SSHAuthMode
    var sshPassword: String
    var sshPrivateKeyPEM: String
    var sshPrivateKeyPassphrase: String
    var remoteNvdrCommand: String

    // Relay (forwarded as nvdr --ipc args on the bridge)
    var relayHost: String
    var relayPort: Int
    var channel: String
    var fingerprint: String
    var insecure: Bool

    // Local input
    var nvdaModifier: NvdaModifier
    var leftOptionMapping: ModifierMapping
    var rightOptionMapping: ModifierMapping
    var commandMapping: ModifierMapping

    // Speech
    var speechRate: Float
    var voiceIdentifier: String?

    init() {
        let d = UserDefaults.standard
        sshHost = d.string(forKey: Keys.sshHost) ?? ""
        sshPort = d.object(forKey: Keys.sshPort) as? Int ?? 22
        sshUser = d.string(forKey: Keys.sshUser) ?? ""
        sshAuthMode = SSHAuthMode(rawValue: d.string(forKey: Keys.sshAuthMode) ?? "") ?? .password
        sshPassword = d.string(forKey: Keys.sshPassword) ?? ""
        sshPrivateKeyPEM = d.string(forKey: Keys.sshPrivateKeyPEM) ?? ""
        sshPrivateKeyPassphrase = d.string(forKey: Keys.sshPrivateKeyPassphrase) ?? ""
        remoteNvdrCommand = d.string(forKey: Keys.remoteNvdrCommand) ?? "nvdr"
        relayHost = d.string(forKey: Keys.relayHost) ?? "nvdaremote.com"
        relayPort = d.object(forKey: Keys.relayPort) as? Int ?? 6837
        channel = d.string(forKey: Keys.channel) ?? ""
        fingerprint = d.string(forKey: Keys.fingerprint) ?? ""
        insecure = d.bool(forKey: Keys.insecure)
        nvdaModifier = NvdaModifier(rawValue: d.string(forKey: Keys.nvdaModifier) ?? "") ?? .capsLock
        leftOptionMapping = ModifierMapping(rawValue: d.string(forKey: Keys.leftOptionMapping) ?? "") ?? .win
        rightOptionMapping = ModifierMapping(rawValue: d.string(forKey: Keys.rightOptionMapping) ?? "") ?? .ctrl
        commandMapping = ModifierMapping(rawValue: d.string(forKey: Keys.commandMapping) ?? "") ?? .alt
        let storedRate = d.object(forKey: Keys.speechRate) as? Double
        speechRate = Float(storedRate ?? 0.55)
        voiceIdentifier = d.string(forKey: Keys.voiceIdentifier)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(sshHost, forKey: Keys.sshHost)
        d.set(sshPort, forKey: Keys.sshPort)
        d.set(sshUser, forKey: Keys.sshUser)
        d.set(sshAuthMode.rawValue, forKey: Keys.sshAuthMode)
        d.set(sshPassword, forKey: Keys.sshPassword)
        d.set(sshPrivateKeyPEM, forKey: Keys.sshPrivateKeyPEM)
        d.set(sshPrivateKeyPassphrase, forKey: Keys.sshPrivateKeyPassphrase)
        d.set(remoteNvdrCommand, forKey: Keys.remoteNvdrCommand)
        d.set(relayHost, forKey: Keys.relayHost)
        d.set(relayPort, forKey: Keys.relayPort)
        d.set(channel, forKey: Keys.channel)
        d.set(fingerprint, forKey: Keys.fingerprint)
        d.set(insecure, forKey: Keys.insecure)
        d.set(nvdaModifier.rawValue, forKey: Keys.nvdaModifier)
        d.set(leftOptionMapping.rawValue, forKey: Keys.leftOptionMapping)
        d.set(rightOptionMapping.rawValue, forKey: Keys.rightOptionMapping)
        d.set(commandMapping.rawValue, forKey: Keys.commandMapping)
        d.set(Double(speechRate), forKey: Keys.speechRate)
        if let id = voiceIdentifier {
            d.set(id, forKey: Keys.voiceIdentifier)
        } else {
            d.removeObject(forKey: Keys.voiceIdentifier)
        }
    }

    /// Build the remote nvdr --ipc invocation for the SSH exec channel.
    /// Whitespace / shell-meta in `channel` is shell-quoted so it can't break
    /// out of the remote command.
    func remoteCommand() -> String {
        var argv: [String] = []
        let cmd = remoteNvdrCommand.trimmingCharacters(in: .whitespaces)
        argv.append(cmd.isEmpty ? "nvdr" : cmd)
        argv.append("--ipc")
        argv.append("--host"); argv.append(relayHost)
        argv.append("--port"); argv.append(String(relayPort))
        argv.append("--channel"); argv.append(channel)
        if !fingerprint.isEmpty {
            argv.append("--fingerprint"); argv.append(fingerprint)
        }
        if insecure {
            argv.append("--insecure")
        }
        return argv.map(shellQuote).joined(separator: " ")
    }

    private enum Keys {
        static let sshHost = "nvdr.sshHost"
        static let sshPort = "nvdr.sshPort"
        static let sshUser = "nvdr.sshUser"
        static let sshAuthMode = "nvdr.sshAuthMode"
        static let sshPassword = "nvdr.sshPassword"
        static let sshPrivateKeyPEM = "nvdr.sshPrivateKeyPEM"
        static let sshPrivateKeyPassphrase = "nvdr.sshPrivateKeyPassphrase"
        static let remoteNvdrCommand = "nvdr.remoteNvdrCommand"
        static let relayHost = "nvdr.relayHost"
        static let relayPort = "nvdr.relayPort"
        static let channel = "nvdr.channel"
        static let fingerprint = "nvdr.fingerprint"
        static let insecure = "nvdr.insecure"
        static let nvdaModifier = "nvdr.nvdaModifier"
        static let leftOptionMapping = "nvdr.leftOptionMapping"
        static let rightOptionMapping = "nvdr.rightOptionMapping"
        static let commandMapping = "nvdr.commandMapping"
        static let speechRate = "nvdr.speechRate"
        static let voiceIdentifier = "nvdr.voiceIdentifier"
    }
}

/// POSIX single-quote shell quoting. Equivalent to Python's `shlex.quote`.
private func shellQuote(_ s: String) -> String {
    if s.isEmpty { return "''" }
    let safe = s.allSatisfy { ch in
        ch.isLetter || ch.isNumber || "@%+=:,./-_".contains(ch)
    }
    if safe { return s }
    return "'" + s.replacing("'", with: "'\\''") + "'"
}
