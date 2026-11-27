import CryptoKit
import Foundation

/// What an update's signature covers, and how it is checked (SPEC §2.11). The release workflow
/// signs with `scripts/update-signing.swift`, which builds the same message.
///
/// The message names the version, the archive's size and its SHA-256, so a signature cannot be
/// moved to another archive or replayed for another version:
///
///     breakpoint-update-v1
///     version 0.2.0
///     size 5242880
///     sha256 3f2a…
public enum UpdateSignature {
    public static func message(version: String, size: Int, sha256: String) -> Data {
        Data("breakpoint-update-v1\nversion \(version)\nsize \(size)\nsha256 \(sha256.lowercased())\n".utf8)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The public key, if `base64` is a 32-byte Ed25519 key.
    public static func publicKey(_ base64: String?) -> Curve25519.Signing.PublicKey? {
        guard let base64, let raw = Data(base64Encoded: base64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    public static func isValid(signature: String, version: String, size: Int, sha256: String, publicKeyBase64: String?) -> Bool {
        guard let key = publicKey(publicKeyBase64), let signatureData = Data(base64Encoded: signature) else { return false }
        return key.isValidSignature(signatureData, for: message(version: version, size: size, sha256: sha256))
    }

    /// Signs as the release workflow does (tests and the harness's throwaway keys only).
    public static func sign(version: String, archive: Data, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let signature = try privateKey.signature(for: message(version: version, size: archive.count,
                                                              sha256: sha256Hex(archive)))
        return signature.base64EncodedString()
    }
}
