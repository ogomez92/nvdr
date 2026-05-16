import Foundation

/// Wire format spoken by `nvdr --ipc`. The Rust side is `src/ipc.rs`. Plain
/// ASCII, line-oriented, one event per line.
///
/// We send: `key <vk> <0|1>`, `combo <spec>`, `type <text>`, `release_all`,
/// `quit`. We receive: `speak <text>`, `cancel`, `state <name>`,
/// `error <message>`. Anything else on stdout is logged and dropped.
enum IPCEvent: Sendable, Equatable {
    case speak(String)
    case cancel
    case state(BridgeState)
    case error(String)
    case unknown(String)
}

enum BridgeState: String, Sendable {
    case connecting
    case ready
    case nvdaNotConnected = "nvda_not_connected"
    case disconnected
    case quit
    case unknown
}

enum IPCCommand: Sendable {
    case key(vk: UInt16, pressed: Bool)
    case combo(String)
    case type(String)
    case sas
    case releaseAll
    case quit

    var line: String {
        switch self {
        case let .key(vk, pressed):
            return "key \(vk) \(pressed ? 1 : 0)"
        case let .combo(spec):
            return "combo \(spec)"
        case let .type(text):
            return "type \(escape(text))"
        case .sas:
            return "sas"
        case .releaseAll:
            return "release_all"
        case .quit:
            return "quit"
        }
    }

    /// Mirror of the `unescape` in `src/ipc.rs` (`\n`, `\r`, `\t`, `\\`).
    private func escape(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }
}

enum IPCParser {
    static func parse(_ raw: String) -> IPCEvent {
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        if line.isEmpty { return .unknown("") }
        let split = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let head = String(split[0])
        let rest = split.count > 1 ? String(split[1]) : ""
        switch head {
        case "speak":
            return .speak(rest)
        case "cancel":
            return .cancel
        case "state":
            return .state(BridgeState(rawValue: rest) ?? .unknown)
        case "error":
            return .error(rest)
        default:
            return .unknown(line)
        }
    }
}
