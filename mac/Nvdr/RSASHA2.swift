import Foundation
import Crypto
import _CryptoExtras
import NIOCore
import NIOSSH

// MARK: - SSH wire helpers

private extension ByteBuffer {
    /// Write an SSH `mpint` (RFC 4251 §5) for a positive integer whose
    /// big-endian unsigned bytes are in `bytes`. We prepend `0x00` if the
    /// high bit of the first byte is set, so the value parses as positive.
    @discardableResult
    mutating func writeSSHMPint(_ bytes: Data) -> Int {
        var trimmed = bytes
        while trimmed.first == 0x00, trimmed.count > 1 {
            trimmed = trimmed.dropFirst()
        }
        var prefixed = Data()
        if let first = trimmed.first, first & 0x80 != 0 {
            prefixed.append(0x00)
        }
        prefixed.append(trimmed)
        return self.writeSSHString(prefixed)
    }

    @discardableResult
    mutating func writeSSHString(_ data: Data) -> Int {
        let written = self.writeInteger(UInt32(data.count))
        return written + self.writeBytes(data)
    }

    @discardableResult
    mutating func writeSSHString<S: Sequence>(_ utf8: S) -> Int where S.Element == UInt8 {
        let bytes = Array(utf8)
        let written = self.writeInteger(UInt32(bytes.count))
        return written + self.writeBytes(bytes)
    }

    mutating func readSSHData() -> Data? {
        guard
            let len: UInt32 = self.readInteger(),
            let bytes = self.readBytes(length: Int(len))
        else { return nil }
        return Data(bytes)
    }
}

// MARK: - The shared public-key payload

/// Wire representation common to ssh-rsa, rsa-sha2-256, rsa-sha2-512: per
/// RFC 4253 §6.6 an `ssh-rsa` public key is `mpint e` then `mpint n`.
/// The algorithm prefix differs across the three but the body is identical,
/// which is what RFC 8332 §3 codifies. Several SSH servers (notably
/// OpenSSH) accept the algorithm name in the blob prefix to negotiate the
/// signature scheme.
struct RSAPublicKeyBody: Equatable {
    let n: Data
    let e: Data

    func write(to buffer: inout ByteBuffer) {
        buffer.writeSSHMPint(e)
        buffer.writeSSHMPint(n)
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSAPublicKeyBody {
        guard let eRaw = buffer.readSSHData(), let nRaw = buffer.readSSHData() else {
            throw RSASHA2Error.truncatedKeyBlob
        }
        // Strip the leading sign byte if present (for parity with mpint
        // semantics from a peer).
        func unsign(_ d: Data) -> Data {
            (d.first == 0x00 && d.count > 1) ? d.dropFirst() : d
        }
        return RSAPublicKeyBody(n: unsign(nRaw), e: unsign(eRaw))
    }
}

enum RSASHA2Error: LocalizedError {
    case truncatedKeyBlob
    case truncatedSignature

    var errorDescription: String? {
        switch self {
        case .truncatedKeyBlob: return "RSA public key blob truncated."
        case .truncatedSignature: return "RSA signature blob truncated."
        }
    }
}

// MARK: - Signature types

struct RSASHA256Signature: NIOSSHSignatureProtocol {
    static let signaturePrefix = "rsa-sha2-256"
    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSASHA256Signature {
        guard let raw = buffer.readSSHData() else { throw RSASHA2Error.truncatedSignature }
        return RSASHA256Signature(rawRepresentation: raw)
    }
}

struct RSASHA512Signature: NIOSSHSignatureProtocol {
    static let signaturePrefix = "rsa-sha2-512"
    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSASHA512Signature {
        guard let raw = buffer.readSSHData() else { throw RSASHA2Error.truncatedSignature }
        return RSASHA512Signature(rawRepresentation: raw)
    }
}

// MARK: - Public key types

/// Two near-identical public-key types, one per signature algorithm. NIOSSH
/// keys algorithm registration off `publicKeyPrefix`, so we can't share a
/// single type across both.
struct RSASHA256PublicKey: NIOSSHPublicKeyProtocol {
    static let publicKeyPrefix = "rsa-sha2-256"
    let body: RSAPublicKeyBody
    let crypto: _RSA.Signing.PublicKey

    var rawRepresentation: Data {
        var buf = ByteBufferAllocator().buffer(capacity: body.n.count + body.e.count + 16)
        body.write(to: &buf)
        return Data(buf.readableBytesView)
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let sig = signature as? RSASHA256Signature else { return false }
        let rsaSig = _RSA.Signing.RSASignature(rawRepresentation: sig.rawRepresentation)
        let digest = SHA256.hash(data: Data(data))
        return crypto.isValidSignature(rsaSig, for: digest, padding: .insecurePKCS1v1_5)
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        let before = buffer.writerIndex
        body.write(to: &buffer)
        return buffer.writerIndex - before
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSASHA256PublicKey {
        let body = try RSAPublicKeyBody.read(from: &buffer)
        let crypto = try _RSA.Signing.PublicKey(n: body.n, e: body.e)
        return RSASHA256PublicKey(body: body, crypto: crypto)
    }
}

struct RSASHA512PublicKey: NIOSSHPublicKeyProtocol {
    static let publicKeyPrefix = "rsa-sha2-512"
    let body: RSAPublicKeyBody
    let crypto: _RSA.Signing.PublicKey

    var rawRepresentation: Data {
        var buf = ByteBufferAllocator().buffer(capacity: body.n.count + body.e.count + 16)
        body.write(to: &buf)
        return Data(buf.readableBytesView)
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let sig = signature as? RSASHA512Signature else { return false }
        let rsaSig = _RSA.Signing.RSASignature(rawRepresentation: sig.rawRepresentation)
        let digest = SHA512.hash(data: Data(data))
        return crypto.isValidSignature(rsaSig, for: digest, padding: .insecurePKCS1v1_5)
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        let before = buffer.writerIndex
        body.write(to: &buffer)
        return buffer.writerIndex - before
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSASHA512PublicKey {
        let body = try RSAPublicKeyBody.read(from: &buffer)
        let crypto = try _RSA.Signing.PublicKey(n: body.n, e: body.e)
        return RSASHA512PublicKey(body: body, crypto: crypto)
    }
}

// MARK: - Private key types

/// We hold two parallel NIOSSHPrivateKey types — one signs SHA-256 + PKCS#1
/// v1.5, the other SHA-512 + PKCS#1 v1.5. The actual private exponent /
/// prime factors live in a single shared `_RSA.Signing.PrivateKey`.
struct RSASHA256PrivateKey: NIOSSHPrivateKeyProtocol {
    static let keyPrefix = "rsa-sha2-256"
    let key: _RSA.Signing.PrivateKey
    let body: RSAPublicKeyBody

    var publicKey: NIOSSHPublicKeyProtocol {
        RSASHA256PublicKey(body: body, crypto: key.publicKey)
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let digest = SHA256.hash(data: Data(data))
        let sig = try key.signature(for: digest, padding: .insecurePKCS1v1_5)
        return RSASHA256Signature(rawRepresentation: sig.rawRepresentation)
    }
}

struct RSASHA512PrivateKey: NIOSSHPrivateKeyProtocol {
    static let keyPrefix = "rsa-sha2-512"
    let key: _RSA.Signing.PrivateKey
    let body: RSAPublicKeyBody

    var publicKey: NIOSSHPublicKeyProtocol {
        RSASHA512PublicKey(body: body, crypto: key.publicKey)
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let digest = SHA512.hash(data: Data(data))
        let sig = try key.signature(for: digest, padding: .insecurePKCS1v1_5)
        return RSASHA512Signature(rawRepresentation: sig.rawRepresentation)
    }
}

// MARK: - Helpers to construct the private keys from an OpenSSH PEM

extension RSASHA256PrivateKey {
    init(openSSHPEM: String) throws {
        let parts = try RSAOpenSSH.parse(pem: openSSHPEM)
        self.key = try _RSA.Signing.PrivateKey(n: parts.n, e: parts.e, d: parts.d, p: parts.p, q: parts.q)
        self.body = RSAPublicKeyBody(n: parts.n, e: parts.e)
    }
}

extension RSASHA512PrivateKey {
    init(openSSHPEM: String) throws {
        let parts = try RSAOpenSSH.parse(pem: openSSHPEM)
        self.key = try _RSA.Signing.PrivateKey(n: parts.n, e: parts.e, d: parts.d, p: parts.p, q: parts.q)
        self.body = RSAPublicKeyBody(n: parts.n, e: parts.e)
    }
}
