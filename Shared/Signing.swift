import Foundation
import CryptoKit
import Security

/// The two key types Kalshi accepts.
public enum KalshiKeyType: String, Codable, Sendable {
    case ed25519
    case rsa
}

public enum SigningError: Error, LocalizedError {
    case badPEM
    case unsupportedKey
    case rsaFailure(String)

    public var errorDescription: String? {
        switch self {
        case .badPEM: return "That doesn't look like a PEM private key."
        case .unsupportedKey: return "Unsupported key type. Kalshi keys are Ed25519 or RSA-2048."
        case .rsaFailure(let s): return "RSA signing failed: \(s)"
        }
    }
}

/// A stored Kalshi API credential. `privateKey` is:
///  - Ed25519: the 32-byte seed
///  - RSA:     PKCS#1 DER bytes
public struct KalshiCredential: Codable, Equatable, Sendable {
    public var keyID: String
    public var keyType: KalshiKeyType
    public var privateKey: Data
    public var environment: KalshiEnvironment
    public var label: String

    public init(keyID: String, keyType: KalshiKeyType, privateKey: Data,
                environment: KalshiEnvironment, label: String = "Spex Glance") {
        self.keyID = keyID
        self.keyType = keyType
        self.privateKey = privateKey
        self.environment = environment
        self.label = label
    }

    // MARK: Generation (the wizard's default path)

    /// Generate a fresh Ed25519 key pair on-device. Returns the credential (with an
    /// empty keyID the user fills in later) and the PEM public key to paste into Kalshi.
    public static func generateEd25519(environment: KalshiEnvironment) -> (credential: KalshiCredential, publicKeyPEM: String) {
        let key = Curve25519.Signing.PrivateKey()
        let cred = KalshiCredential(keyID: "", keyType: .ed25519,
                                    privateKey: key.rawRepresentation, environment: environment)
        return (cred, PEM.ed25519PublicKeyPEM(key.publicKey.rawRepresentation))
    }

    // MARK: Signing

    /// Sign Kalshi's pre-sign text: `timestampMs + METHOD + path-without-query`.
    public func sign(_ message: String) throws -> Data {
        let data = Data(message.utf8)
        switch keyType {
        case .ed25519:
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
            return try key.signature(for: data)
        case .rsa:
            return try RSA.signPSS(pkcs1DER: privateKey, message: data)
        }
    }
}

// MARK: - RSA-PSS via Security.framework (for Kalshi-generated keys)

enum RSA {
    static func secKey(fromPKCS1 der: Data) throws -> SecKey {
        // Kalshi issues 2048-bit keys; accept 3072/4096 too rather than hard-coding one size.
        var lastError = "invalid key"
        for bits in [2048, 3072, 4096] {
            let attrs: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits: bits,
            ]
            var err: Unmanaged<CFError>?
            if let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &err) { return key }
            lastError = err?.takeRetainedValue().localizedDescription ?? lastError
        }
        throw SigningError.rsaFailure(lastError)
    }

    /// RSA-PSS, SHA-256, MGF1-SHA256, salt length = digest length (Apple's default for this algorithm).
    static func signPSS(pkcs1DER: Data, message: Data) throws -> Data {
        let key = try secKey(fromPKCS1: pkcs1DER)
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePSSSHA256,
                                              message as CFData, &err) else {
            throw SigningError.rsaFailure(err?.takeRetainedValue().localizedDescription ?? "sign failed")
        }
        return sig as Data
    }
}

// MARK: - PEM parsing / formatting

public enum PEM {
    /// Parse any PEM Kalshi hands out (RSA PKCS#1, RSA PKCS#8, Ed25519 PKCS#8) or that
    /// `openssl genpkey` produces. Returns the key type and the bytes `KalshiCredential` stores.
    public static func parsePrivateKey(_ pem: String) throws -> (KalshiKeyType, Data) {
        let body = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
        guard let der = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else {
            throw SigningError.badPEM
        }

        if pem.contains("BEGIN RSA PRIVATE KEY") {
            return (.rsa, der)                       // PKCS#1 as-is
        }

        // PKCS#8: look at the AlgorithmIdentifier OID.
        let ed25519OID: [UInt8] = [0x06, 0x03, 0x2B, 0x65, 0x70]
        let rsaOID: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]

        if der.range(of: Data(ed25519OID)) != nil {
            // RFC 8410: PrivateKey ::= OCTET STRING (len 0x22) wrapping CurvePrivateKey ::= OCTET STRING (len 0x20).
            // Scan for `04 22 04 20` rather than taking the last 32 bytes, so PKCS#8 v2 files
            // (which append the public key after the seed) parse correctly.
            let marker: [UInt8] = [0x04, 0x22, 0x04, 0x20]
            if let r = der.range(of: Data(marker)), r.upperBound + 32 <= der.count {
                return (.ed25519, der[r.upperBound ..< r.upperBound + 32])
            }
            throw SigningError.badPEM
        }
        if der.range(of: Data(rsaOID)) != nil {
            // Unwrap PKCS#8 -> PKCS#1: the inner key is the contents of the OCTET STRING
            // that follows the AlgorithmIdentifier. Find the OCTET STRING with a 2-byte length.
            let bytes = [UInt8](der)
            var i = 0
            while i + 3 < bytes.count {
                if bytes[i] == 0x04 && bytes[i + 1] == 0x82 {
                    let len = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
                    let start = i + 4
                    if start + len <= bytes.count {
                        return (.rsa, Data(bytes[start ..< start + len]))
                    }
                }
                i += 1
            }
            throw SigningError.badPEM
        }
        throw SigningError.unsupportedKey
    }

    /// Ed25519 public key as SubjectPublicKeyInfo PEM — what Kalshi's "paste your public key" field wants.
    public static func ed25519PublicKeyPEM(_ raw: Data) -> String {
        // SPKI prefix for Ed25519: 30 2a 30 05 06 03 2b 65 70 03 21 00
        let prefix: [UInt8] = [0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00]
        let der = Data(prefix) + raw
        let b64 = der.base64EncodedString(options: [.lineLength64Characters])
        return "-----BEGIN PUBLIC KEY-----\n\(b64)\n-----END PUBLIC KEY-----\n"
    }
}
