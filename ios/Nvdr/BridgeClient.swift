import Foundation
import Observation
import Citadel
import Crypto
import NIOCore
import NIOPosix
import NIOSSH

/// Carry a non-Sendable value across an actor boundary when we know the
/// underlying access is thread-safe (NIO Channels are event-loop-safe).
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Drives the bridge end-to-end:
///   iOS BT keyboard → BridgeClient → SSH → `nvdr --ipc` → relay → slave NVDA
///                     ←——— stdout (speak/cancel/state) ←———————————————————
///
/// Lifecycle is intentionally close to the Python add-on's `NvdrBridge` in
/// `addon/globalPlugins/nvdrBridge/__init__.py`: connect on `start`, parse
/// line-oriented IPC, surface a connected/passthrough toggle to the UI.
@Observable
@MainActor
final class BridgeClient {
    enum Status: Equatable, Sendable {
        case idle
        case connecting
        case authenticating
        case ready
        case nvdaNotConnected
        case disconnected(reason: String)
        case failed(message: String)
    }

    private(set) var status: Status = .idle
    private(set) var lastSpeech: String = ""
    private(set) var log: [String] = []

    /// User-controlled toggle (NVDA add-on calls this "passthrough"). When
    /// `true`, BT keystrokes flow to the slave; when `false`, they're handled
    /// locally. Independent of `status`: the connection can be ready while
    /// forwarding is off. Defaults to on — most sessions want forwarding the
    /// moment they connect, and the user can flip it off when they need to
    /// interact with the iPhone normally.
    var forwardingEnabled: Bool = true {
        didSet {
            if !forwardingEnabled, oldValue {
                send(.releaseAll)
            }
        }
    }

    private var driver: Task<Void, Never>?
    private var commandContinuation: AsyncStream<IPCCommand>.Continuation?
    private let speech: SpeechOutput

    init(speech: SpeechOutput) {
        self.speech = speech
    }

    func start(_ settings: AppSettings) {
        stop()
        let host = settings.sshHost
        let port = settings.sshPort
        let user = settings.sshUser
        let remote = settings.remoteCommand()

        guard !host.isEmpty, !user.isEmpty, !settings.channel.isEmpty else {
            status = .failed(message: "Set SSH host, user, and channel in Settings.")
            return
        }

        let authBlueprint = AuthBlueprint(
            user: user,
            mode: settings.sshAuthMode,
            password: settings.sshPassword,
            privateKeyPEM: settings.sshPrivateKeyPEM,
            passphrase: settings.sshPrivateKeyPassphrase
        )
        // Parse the key up front so we can both fail fast and log the
        // resulting type + fingerprint — that's the diagnostic the user needs
        // to compare against `ssh-keygen -lf` server-side.
        let parsed: ParsedKey
        do {
            parsed = try Self.parseAuth(blueprint: authBlueprint)
        } catch {
            status = .failed(message: "auth: \(error.localizedDescription)")
            appendLog("auth setup failed: \(error.localizedDescription)")
            return
        }

        let (stream, cont) = AsyncStream<IPCCommand>.makeStream()
        commandContinuation = cont
        status = .connecting
        appendLog("connecting to \(user)@\(host):\(port) using \(parsed.kind)")
        if let fp = parsed.fingerprint {
            appendLog("offered pubkey fingerprint: \(fp)")
            appendLog("server-side check: ssh-keygen -lf ~/.ssh/authorized_keys | grep \(fp.replacingOccurrences(of: "/", with: "\\/"))")
        }

        driver = Task { [weak self] in
            await self?.runDriver(
                host: host, port: port, blueprint: authBlueprint,
                remote: remote, commandStream: stream
            )
        }
    }

    /// Snapshot of the auth-relevant settings, captured on the MainActor and
    /// passed to the nonisolated builder. Avoids cross-actor property access.
    struct AuthBlueprint: Sendable {
        let user: String
        let mode: SSHAuthMode
        let password: String
        let privateKeyPEM: String
        let passphrase: String
    }

    /// Outcome of attempting to parse a private key. Used both to build the
    /// auth method and to surface "what type did we end up offering and what
    /// is its public-key fingerprint" so the user can match it against
    /// `ssh-keygen -lf id_ed25519.pub` on the bridge.
    struct ParsedKey {
        let auth: SSHAuthenticationMethod
        let kind: String
        let fingerprint: String?
    }

    nonisolated private static func makeAuth(blueprint b: AuthBlueprint) throws -> SSHAuthenticationMethod {
        try parseAuth(blueprint: b).auth
    }

    nonisolated private static func parseAuth(blueprint b: AuthBlueprint) throws -> ParsedKey {
        switch b.mode {
        case .password:
            return ParsedKey(
                auth: .passwordBased(username: b.user, password: b.password),
                kind: "password", fingerprint: nil
            )
        case .privateKey:
            let pem = b.privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pem.isEmpty else { throw AuthError.missingKey }

            if !pem.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") {
                throw AuthError.wrongKeyFormat(detected: detectFormat(pem))
            }

            let passphrase = b.passphrase.isEmpty ? nil : Data(b.passphrase.utf8)

            // Try ed25519 first; the inner parser verifies the public-key
            // prefix and bails cleanly if the key is the wrong type.
            if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: passphrase) {
                let fp = ed25519Fingerprint(publicKey: key.publicKey.rawRepresentation)
                return ParsedKey(
                    auth: .ed25519(username: b.user, privateKey: key),
                    kind: "ssh-ed25519", fingerprint: fp
                )
            }

            // Fall through to RSA. We use our own parser + auth delegate
            // (rather than Citadel's `.rsa(...)`) so we can sign with
            // SHA-256 / SHA-512 — the only RSA signature algorithms that
            // OpenSSH 8.7+ accepts by default. Citadel's built-in RSA only
            // produces SHA-1 (`ssh-rsa`), which modern servers reject as
            // "all auth methods failed" even when the key is authorized.
            let parts: RSAOpenSSH.PrivateKeyComponents
            do {
                parts = try RSAOpenSSH.parse(pem: pem)
            } catch {
                throw AuthError.unsupportedKey(detail: "\(error.localizedDescription)")
            }
            let delegate = RSASHA2AuthDelegate(username: b.user, openSSHPrivateKeyPEM: pem)
            let auth: SSHAuthenticationMethod = .custom(delegate)
            let fp = rsaFingerprint(n: parts.n, e: parts.e)
            return ParsedKey(auth: auth, kind: "rsa-sha2-512/256", fingerprint: fp)
        }
    }

    /// SHA-256 fingerprint of an RSA public key in OpenSSH wire format
    /// (`string("ssh-rsa") + mpint(e) + mpint(n)`), printed the same way
    /// `ssh-keygen -lf id_rsa.pub` does.
    nonisolated private static func rsaFingerprint(n: Data, e: Data) -> String {
        var blob = Data()
        func appendString(_ bytes: Data) {
            var len = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &len) { blob.append(contentsOf: $0) }
            blob.append(bytes)
        }
        func appendMPInt(_ bytes: Data) {
            var trimmed = bytes
            while trimmed.first == 0x00, trimmed.count > 1 { trimmed = trimmed.dropFirst() }
            var prefixed = Data()
            if let first = trimmed.first, first & 0x80 != 0 { prefixed.append(0x00) }
            prefixed.append(trimmed)
            appendString(prefixed)
        }
        appendString(Data("ssh-rsa".utf8))
        appendMPInt(e)
        appendMPInt(n)
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(b64)"
    }

    /// SSH-style SHA256 base64 fingerprint of an ed25519 public key, in the
    /// same format `ssh-keygen -lf` prints: `SHA256:<base64-no-padding>`.
    nonisolated private static func ed25519Fingerprint(publicKey: Data) -> String {
        // OpenSSH wire format: string("ssh-ed25519") + string(rawPublicKey).
        // Each "string" is uint32(big-endian length) + bytes.
        var blob = Data()
        let typeStr = "ssh-ed25519"
        var typeLen = UInt32(typeStr.utf8.count).bigEndian
        withUnsafeBytes(of: &typeLen) { blob.append(contentsOf: $0) }
        blob.append(contentsOf: typeStr.utf8)
        var keyLen = UInt32(publicKey.count).bigEndian
        withUnsafeBytes(of: &keyLen) { blob.append(contentsOf: $0) }
        blob.append(publicKey)
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(b64)"
    }

    nonisolated private static func detectFormat(_ pem: String) -> String {
        if pem.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") {
            return "PEM/PKCS#1 RSA"
        }
        if pem.hasPrefix("-----BEGIN EC PRIVATE KEY-----") {
            return "PEM/SEC1 ECDSA"
        }
        if pem.hasPrefix("-----BEGIN PRIVATE KEY-----") {
            return "PEM/PKCS#8"
        }
        if pem.hasPrefix("-----BEGIN ENCRYPTED PRIVATE KEY-----") {
            return "PEM/PKCS#8 (encrypted)"
        }
        if pem.hasPrefix("-----BEGIN DSA PRIVATE KEY-----") {
            return "PEM/PKCS#1 DSA"
        }
        if pem.contains("PUBLIC KEY") {
            return "public key (you need the private key)"
        }
        return "unrecognized"
    }

    enum AuthError: LocalizedError {
        case missingKey
        case wrongKeyFormat(detected: String)
        case unsupportedKey(detail: String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "Paste an OpenSSH private key in Settings."
            case .wrongKeyFormat(let detected):
                return "Key is not in OpenSSH format (looks like \(detected)). Convert with: `ssh-keygen -p -N '' -f <keyfile>` (to OpenSSH format) or generate a fresh ed25519 key with `ssh-keygen -t ed25519`."
            case .unsupportedKey(let detail):
                return "Key parse failed: \(detail)"
            }
        }
    }

    func stop() {
        send(.quit)
        commandContinuation?.finish()
        commandContinuation = nil
        driver?.cancel()
        driver = nil
        forwardingEnabled = false
        if case .ready = status { status = .disconnected(reason: "stopped") }
    }

    /// Send an IPC command to the bridge. Silently dropped if not connected —
    /// matches the add-on's behavior (it logs a warning and moves on).
    func send(_ command: IPCCommand) {
        commandContinuation?.yield(command)
    }

    func sendKey(vk: UInt16, pressed: Bool) {
        send(.key(vk: vk, pressed: pressed))
    }

    // -- Speech forwarding ---------------------------------------------------

    func previewSpeech(_ sample: String? = nil) {
        let speech = self.speech
        Task {
            if let sample {
                await speech.preview(sample)
            } else {
                await speech.preview()
            }
        }
    }

    func setSpeechRate(_ rate: Float) {
        let speech = self.speech
        Task { await speech.setRate(rate) }
    }

    func setSpeechVoice(_ identifier: String?) {
        let speech = self.speech
        Task { await speech.setVoice(identifier: identifier) }
    }

    nonisolated private func runDriver(
        host: String, port: Int, blueprint: AuthBlueprint,
        remote: String, commandStream: AsyncStream<IPCCommand>
    ) async {
        do {
            await setStatus(.authenticating)
            // Re-build the auth object inside the nonisolated task — the
            // SSHAuthenticationMethod class isn't Sendable so we can't carry
            // it across the actor boundary. The blueprint is plain data.
            let auth = try Self.makeAuth(blueprint: blueprint)
            // Register our rsa-sha2-256/512 plugins so that the SHA-2 RSA
            // signatures our delegate produces are recognised by NIOSSH's
            // outbound serializer. Without this, our custom NIOSSHPrivateKey
            // would still be wrapped but the wire serializer wouldn't know
            // the algorithm prefix.
            var algorithms = SSHAlgorithms()
            algorithms.publicKeyAlgorihtms = .add([
                (RSASHA512PublicKey.self, RSASHA512Signature.self),
                (RSASHA256PublicKey.self, RSASHA256Signature.self),
            ])
            let client = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: auth,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never,
                algorithms: algorithms
            )
            await appendLogAsync("ssh authenticated; spawning: \(remote)")

            try await client.withExec(remote) { inbound, outbound in
                // The TTY handles wrap a NIO Channel which isn't formally
                // Sendable but is fully thread-safe at the event-loop layer.
                // Wrap to silence strict-concurrency warnings without
                // pretending the types themselves are Sendable.
                let safeIn = UncheckedSendable(inbound)
                let safeOut = UncheckedSendable(outbound)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [safeOut] in
                        for await cmd in commandStream {
                            let line = cmd.line + "\n"
                            var buf = ByteBuffer()
                            buf.writeString(line)
                            do {
                                try await safeOut.value.write(buf)
                            } catch {
                                await self.appendLogAsync("stdin write failed: \(error)")
                                return
                            }
                        }
                    }
                    group.addTask { [safeIn] in
                        // stdout chunks arrive at arbitrary boundaries — split
                        // by newline and feed each line to the IPC parser.
                        var pending = ""
                        for try await event in safeIn.value {
                            switch event {
                            case .stdout(let buffer):
                                let s = String(buffer: buffer)
                                pending += s
                                while let nl = pending.firstIndex(of: "\n") {
                                    let line = String(pending[..<nl])
                                    pending.removeSubrange(...nl)
                                    await self.handle(IPCParser.parse(line))
                                }
                            case .stderr(let buffer):
                                let s = String(buffer: buffer)
                                for chunk in s.split(separator: "\n", omittingEmptySubsequences: false) {
                                    let line = String(chunk)
                                    if !line.isEmpty {
                                        await self.appendLogAsync("nvdr: \(line)")
                                    }
                                }
                            }
                        }
                        if !pending.isEmpty {
                            await self.handle(IPCParser.parse(pending))
                        }
                    }
                    try await group.waitForAll()
                }
            }
            try? await client.close()
            await setStatus(.disconnected(reason: "remote process exited"))
        } catch is CancellationError {
            await setStatus(.disconnected(reason: "stopped"))
        } catch {
            let msg = "\(error)"
            await appendLogAsync("driver error: \(msg)")
            // The bundled SSH library (Citadel + swift-nio-ssh) only signs
            // RSA with SHA-1 (`ssh-rsa`). OpenSSH 8.7+ disables that by
            // default — `authorized_keys` will be a perfect match and the
            // server still rejects you. Surface the actionable fix instead
            // of the opaque "allAuthenticationOptionsFailed".
            if blueprint.mode == .privateKey,
               msg.contains("allAuthenticationOptionsFailed") || msg.contains("authentication") {
                await appendLogAsync(
                    "hint: if your key is RSA, modern sshd (8.7+) rejects ssh-rsa SHA-1. " +
                    "Generate ed25519: `ssh-keygen -t ed25519` and add the .pub to authorized_keys. " +
                    "Or add `PubkeyAcceptedAlgorithms +ssh-rsa` to sshd_config."
                )
            }
            await setStatus(.failed(message: msg))
        }
    }

    nonisolated private func handle(_ event: IPCEvent) async {
        switch event {
        case .speak(let text):
            await setLastSpeech(text)
            await speech.speak(text)
        case .cancel:
            await speech.cancel()
        case .state(let s):
            if let mapped = Self.map(state: s) {
                await setStatus(mapped)
            }
            if s == .disconnected || s == .quit || s == .nvdaNotConnected {
                await turnForwardingOff()
            }
        case .error(let msg):
            await appendLogAsync("relay error: \(msg)")
        case .unknown(let line):
            await appendLogAsync("unknown line: \(line)")
        }
    }

    private func setLastSpeech(_ text: String) {
        lastSpeech = text
    }

    private func turnForwardingOff() {
        if forwardingEnabled { forwardingEnabled = false }
    }

    nonisolated private static func map(state: BridgeState) -> Status? {
        switch state {
        case .connecting: return .connecting
        case .ready: return .ready
        case .nvdaNotConnected: return .nvdaNotConnected
        case .disconnected: return .disconnected(reason: "relay")
        case .quit: return .disconnected(reason: "quit")
        case .unknown: return nil
        }
    }

    private func setStatus(_ s: Status) {
        status = s
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    nonisolated private func appendLogAsync(_ line: String) async {
        await appendLog(line)
    }
}
