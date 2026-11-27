#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import Testing
@testable import BreakpointCore

/// The first-party SHA-2 and Ed25519 that check update signatures where CryptoKit is missing
/// (Windows). Known-answer vectors from FIPS 180-4 and RFC 8032 §7.1; on Apple platforms the same
/// inputs are also checked against CryptoKit.
@Suite("Portable SHA-2 and Ed25519 (update signatures without CryptoKit)")
struct PortableCryptoTests {
    static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    @Test func sha256KnownAnswers() {
        #expect(SHA2.hex(SHA2.sha256(Data())) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA2.hex(SHA2.sha256(Data("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let twoBlocks = Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
        #expect(SHA2.hex(SHA2.sha256(twoBlocks)) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test func sha512KnownAnswer() {
        #expect(SHA2.hex(SHA2.sha512(Array("abc".utf8))) ==
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
    }

    @Test func hashesAgreeWithTheSignatureHelperAtEveryLength() {
        // Padding edges: 55, 56, 63, 64, 111, 112 and 128 bytes.
        for length in [0, 1, 55, 56, 63, 64, 65, 111, 112, 127, 128, 129, 1000] {
            let data = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            #expect(UpdateSignature.sha256Hex(data) == SHA2.hex(SHA2.sha256(data)), "length \(length)")
            #if canImport(CryptoKit)
            let reference = SHA512.hash(data: data).map { $0 }
            #expect(SHA2.sha512(Array(data)) == reference, "length \(length)")
            #endif
        }
    }

    static let rfc8032: [(seed: String, publicKey: String, message: String, signature: String)] = [
        ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
         "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
         "",
         "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
        ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
         "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
         "72",
         "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
        ("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
         "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
         "af82",
         "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"),
    ]

    @Test(arguments: 0..<3) func ed25519KnownAnswers(_ index: Int) {
        let vector = Self.rfc8032[index]
        let seed = Self.bytes(vector.seed), message = Self.bytes(vector.message)
        #expect(Ed25519.publicKey(seed: seed) == Self.bytes(vector.publicKey))
        #expect(Ed25519.sign(message, seed: seed) == Self.bytes(vector.signature))
        #expect(Ed25519.isValid(signature: Self.bytes(vector.signature), message: message, publicKey: Self.bytes(vector.publicKey)))
    }

    @Test func ed25519RejectsTamperedInput() {
        let vector = Self.rfc8032[2]
        let publicKey = Self.bytes(vector.publicKey), signature = Self.bytes(vector.signature)
        let message = Self.bytes(vector.message)
        #expect(!Ed25519.isValid(signature: signature, message: message + [0], publicKey: publicKey))
        for position in [0, 31, 32, 63] {
            var bad = signature
            bad[position] ^= 0x01
            #expect(!Ed25519.isValid(signature: bad, message: message, publicKey: publicKey), "byte \(position)")
        }
        var otherKey = publicKey
        otherKey[0] ^= 0x01
        #expect(!Ed25519.isValid(signature: signature, message: message, publicKey: otherKey))
        #expect(!Ed25519.isValid(signature: Array(signature.prefix(63)), message: message, publicKey: publicKey))
    }

    @Test func ed25519RejectsANonCanonicalScalar() {
        // S + L verifies with TweetNaCl's arithmetic but must be refused (malleability).
        let vector = Self.rfc8032[0]
        var signature = Self.bytes(vector.signature)
        var carry = 0
        for i in 0..<32 {
            let sum = Int(signature[32 + i]) + Int(Ed25519.orderL[i]) + carry
            signature[32 + i] = UInt8(sum & 0xff)
            carry = sum >> 8
        }
        #expect(!Ed25519.isValid(signature: signature, message: [], publicKey: Self.bytes(vector.publicKey)))
    }

    @Test func throwawayKeysSignAndVerifyAnUpdate() throws {
        let key = UpdateSigningKey()
        let archive = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })
        let signature = try UpdateSignature.sign(version: "0.4.0", archive: archive, privateKey: key)
        let sha = UpdateSignature.sha256Hex(archive)
        #expect(UpdateSignature.isValid(signature: signature, version: "0.4.0", size: archive.count, sha256: sha,
                                        publicKeyBase64: key.publicKeyBase64))
        #expect(!UpdateSignature.isValid(signature: signature, version: "0.4.1", size: archive.count, sha256: sha,
                                         publicKeyBase64: key.publicKeyBase64))
        #expect(!UpdateSignature.isValid(signature: signature, version: "0.4.0", size: archive.count, sha256: sha,
                                         publicKeyBase64: UpdateSigningKey().publicKeyBase64))
    }

    #if canImport(CryptoKit)
    @Test func portableEd25519AgreesWithCryptoKit() throws {
        for round in 0..<8 {
            let key = Curve25519.Signing.PrivateKey()
            let seed = Array(key.rawRepresentation)
            let message = Array("round \(round) of the agreement check".utf8)
            #expect(Ed25519.publicKey(seed: seed) == Array(key.publicKey.rawRepresentation))
            // CryptoKit's signatures are randomised; each implementation must accept the other's.
            let theirs = Array(try key.signature(for: Data(message)))
            #expect(Ed25519.isValid(signature: theirs, message: message, publicKey: Array(key.publicKey.rawRepresentation)))
            let ours = Ed25519.sign(message, seed: seed)!
            #expect(key.publicKey.isValidSignature(Data(ours), for: Data(message)))
        }
    }
    #endif
}
