#if canImport(CryptoKit)
import CryptoKit
#endif
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
///
/// Apple platforms check with CryptoKit; elsewhere (Windows) with the first-party `Ed25519` and
/// `SHA2` (no third-party code either way). Tests check that both give the same answers.
public enum UpdateSignature {
    public static func message(version: String, size: Int, sha256: String) -> Data {
        Data("breakpoint-update-v1\nversion \(version)\nsize \(size)\nsha256 \(sha256.lowercased())\n".utf8)
    }

    public static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        SHA2.hex(SHA2.sha256(data))
        #endif
    }

    /// The raw 32-byte public key, if `base64` is one.
    public static func publicKey(_ base64: String?) -> Data? {
        guard let base64, let raw = Data(base64Encoded: base64), raw.count == Ed25519.publicKeyBytes else { return nil }
        #if canImport(CryptoKit)
        guard (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil else { return nil }
        #endif
        return raw
    }

    public static func isValid(signature: String, version: String, size: Int, sha256: String, publicKeyBase64: String?) -> Bool {
        guard let key = publicKey(publicKeyBase64), let signatureData = Data(base64Encoded: signature) else { return false }
        let signed = message(version: version, size: size, sha256: sha256)
        #if canImport(CryptoKit)
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return publicKey.isValidSignature(signatureData, for: signed)
        #else
        return Ed25519.isValid(signature: Array(signatureData), message: Array(signed), publicKey: Array(key))
        #endif
    }

    /// Signs as the release workflow does (tests and the harness's throwaway keys only).
    public static func sign(version: String, archive: Data, privateKey: UpdateSigningKey) throws -> String {
        let signed = message(version: version, size: archive.count, sha256: sha256Hex(archive))
        return try privateKey.signature(for: signed).base64EncodedString()
    }
}

/// An Ed25519 private key: the release key's shape, for tests and the harness's throwaway keys.
/// The real release key never exists outside the release workflow (docs/RELEASING.md).
public struct UpdateSigningKey: Sendable {
    /// The 32-byte seed (CryptoKit's `rawRepresentation`).
    public let rawRepresentation: Data

    /// A fresh random key.
    public init() {
        rawRepresentation = Data(Ed25519.randomSeed())
    }

    public init?(rawRepresentation: Data) {
        guard rawRepresentation.count == Ed25519.seedBytes else { return nil }
        self.rawRepresentation = rawRepresentation
    }

    /// The public half, raw 32 bytes.
    public var publicKey: Data {
        #if canImport(CryptoKit)
        if let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation) {
            return key.publicKey.rawRepresentation
        }
        #endif
        return Data(Ed25519.publicKey(seed: Array(rawRepresentation)) ?? [])
    }

    public var publicKeyBase64: String { publicKey.base64EncodedString() }

    public func signature(for message: Data) throws -> Data {
        #if canImport(CryptoKit)
        return try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation).signature(for: message)
        #else
        guard let signature = Ed25519.sign(Array(message), seed: Array(rawRepresentation)) else {
            throw UpdateInstallError.badSignature
        }
        return Data(signature)
        #endif
    }
}
