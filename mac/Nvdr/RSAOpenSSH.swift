import Foundation

/// Parses an OpenSSH-format RSA private key into the five integers that
/// `_CryptoExtras._RSA.Signing.PrivateKey(n:e:d:p:q:)` wants.
///
/// We do this ourselves because Citadel's parser discards the prime factors
/// (`p`, `q`) after building its own key object, and without `p`/`q` the
/// SHA-2 RSA implementations in swift-crypto / Apple's Security framework
/// can't construct a usable private key.
///
/// Supports unencrypted keys (`Cipher: none`). Encrypted keys throw
/// `RSAOpenSSHError.encryptedKeyUnsupported` with a hint to convert the
/// key — implementing OpenSSH's bcrypt-pbkdf in Swift is a significant
/// project of its own and not worth carrying for v1 of this fix.
///
/// Wire format (RFC-style, see PROTOCOL.key in the OpenSSH source):
/// ```
/// "openssh-key-v1\0"
/// string  ciphername          ("none" for unencrypted)
/// string  kdfname             ("none")
/// string  kdfoptions          ("")
/// uint32  N (number of keys)  (always 1)
/// string  publickey           (public key wire blob)
/// string  encrypted-blob      (== plaintext when ciphername == "none")
///
/// Inside the (decrypted) blob:
/// uint32  checkint
/// uint32  checkint            (must equal the first)
/// string  keytype             ("ssh-rsa")
/// mpint   n   (modulus)
/// mpint   e   (public exponent)
/// mpint   d   (private exponent)
/// mpint   iqmp (q^-1 mod p)
/// mpint   p
/// mpint   q
/// string  comment
/// padding 1, 2, 3, …          (to align to cipher block size)
/// ```
enum RSAOpenSSH {
    struct PrivateKeyComponents {
        let n: Data
        let e: Data
        let d: Data
        let p: Data
        let q: Data
    }

    static func parse(pem: String) throws -> PrivateKeyComponents {
        let header = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let footer = "-----END OPENSSH PRIVATE KEY-----"
        let stripped = pem
            .replacing("\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.hasPrefix(header), stripped.hasSuffix(footer) else {
            throw RSAOpenSSHError.notOpenSSHFormat
        }
        let bodyStart = stripped.index(stripped.startIndex, offsetBy: header.count)
        let bodyEnd = stripped.index(stripped.endIndex, offsetBy: -footer.count)
        let base64 = stripped[bodyStart..<bodyEnd]
            .filter { !$0.isWhitespace }
        guard let raw = Data(base64Encoded: String(base64), options: .ignoreUnknownCharacters) else {
            throw RSAOpenSSHError.invalidBase64
        }

        var reader = ByteReader(data: raw)
        let magic = "openssh-key-v1\0"
        let magicBytes = Data(magic.utf8)
        let head = try reader.readBytes(magicBytes.count)
        guard head == magicBytes else { throw RSAOpenSSHError.badMagic }

        let cipher = try reader.readSSHString()
        let kdf = try reader.readSSHString()
        _ = try reader.readSSHString() // kdfoptions
        let nKeys = try reader.readUInt32()
        guard nKeys == 1 else { throw RSAOpenSSHError.unsupported("multiple keys in one file") }

        if cipher != Data("none".utf8) || kdf != Data("none".utf8) {
            throw RSAOpenSSHError.encryptedKeyUnsupported
        }

        _ = try reader.readSSHString() // public key blob — we only need the private side
        var blob = ByteReader(data: try reader.readSSHString())

        let c0 = try blob.readUInt32()
        let c1 = try blob.readUInt32()
        guard c0 == c1 else { throw RSAOpenSSHError.checkIntMismatch }

        let keyType = try blob.readSSHString()
        guard keyType == Data("ssh-rsa".utf8) else {
            let s = String(data: keyType, encoding: .utf8) ?? "<binary>"
            throw RSAOpenSSHError.notRSAKey(detected: s)
        }

        let n = try blob.readMPInt()
        let e = try blob.readMPInt()
        let d = try blob.readMPInt()
        _ = try blob.readMPInt() // iqmp — _RSA.Signing recomputes from p, q
        let p = try blob.readMPInt()
        let q = try blob.readMPInt()

        return PrivateKeyComponents(n: n, e: e, d: d, p: p, q: q)
    }
}

enum RSAOpenSSHError: LocalizedError {
    case notOpenSSHFormat
    case invalidBase64
    case badMagic
    case truncated
    case unsupported(String)
    case encryptedKeyUnsupported
    case checkIntMismatch
    case notRSAKey(detected: String)

    var errorDescription: String? {
        switch self {
        case .notOpenSSHFormat:
            return "Not an OpenSSH-format key (missing BEGIN/END OPENSSH PRIVATE KEY markers)."
        case .invalidBase64:
            return "OpenSSH key body is not valid base64."
        case .badMagic:
            return "OpenSSH key magic bytes are missing or wrong."
        case .truncated:
            return "OpenSSH key blob is shorter than expected."
        case .unsupported(let what):
            return "Unsupported OpenSSH key feature: \(what)."
        case .encryptedKeyUnsupported:
            return "Encrypted OpenSSH RSA keys aren't supported yet for SHA-2 signing. " +
                   "Either remove the passphrase (`ssh-keygen -p -N '' -f <keyfile>`) " +
                   "or use an ed25519 key, which works without this codepath."
        case .checkIntMismatch:
            return "OpenSSH key checkint mismatch — likely wrong passphrase or corrupted file."
        case .notRSAKey(let detected):
            return "Key inside the OpenSSH container is \(detected), not ssh-rsa."
        }
    }
}

/// Minimal byte/SSH-wire reader. All multi-byte integers are big-endian per
/// SSH convention.
private struct ByteReader {
    let data: Data
    private var offset: Int = 0

    init(data: Data) { self.data = data }

    mutating func readBytes(_ n: Int) throws -> Data {
        guard offset + n <= data.count else { throw RSAOpenSSHError.truncated }
        let slice = data.subdata(in: offset..<(offset + n))
        offset += n
        return slice
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(4)
        return bytes.withUnsafeBytes { ptr in
            ptr.load(as: UInt32.self).bigEndian
        }
    }

    /// SSH `string`: uint32 length + raw bytes.
    mutating func readSSHString() throws -> Data {
        let len = Int(try readUInt32())
        return try readBytes(len)
    }

    /// SSH `mpint` (RFC 4251 §5): uint32 length + two's complement big-endian
    /// bytes. For positive numbers OpenSSH may prepend a leading zero byte to
    /// distinguish from a negative number; we strip it for the unsigned-bytes
    /// view that `_RSA.Signing.PrivateKey` expects.
    mutating func readMPInt() throws -> Data {
        var raw = try readSSHString()
        if let first = raw.first, first == 0x00, raw.count > 1 {
            raw = raw.dropFirst()
        }
        return raw
    }
}
