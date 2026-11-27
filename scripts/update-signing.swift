// The release key's tool (SPEC §2.11, docs/RELEASING.md). Run with `swift scripts/update-signing.swift …`
// (CryptoKit is part of macOS; no third-party code). It builds the same signed message as
// Sources/BreakpointCore/Updates/UpdateSignature.swift; scripts/e2e.sh checks that the two agree.
//
//   keygen PUBLIC_OUT            new key pair: the private key (base64) to stdout, never to disk;
//                                the public key (base64) to the file PUBLIC_OUT
//   public                       the public key of the private key in $UPDATE_SIGNING_KEY
//   sign VERSION ARCHIVE         the signature (base64) of ARCHIVE as VERSION, with $UPDATE_SIGNING_KEY
//   verify VERSION ARCHIVE SIGNATURE PUBLIC_KEY   exit 0 if it verifies, 1 if not
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

func message(version: String, archive: Data) -> Data {
    let sha = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
    return Data("breakpoint-update-v1\nversion \(version)\nsize \(archive.count)\nsha256 \(sha)\n".utf8)
}

func privateKey() -> Curve25519.Signing.PrivateKey {
    guard let base64 = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"], !base64.isEmpty else {
        fail("UPDATE_SIGNING_KEY is not set")
    }
    guard let raw = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("UPDATE_SIGNING_KEY is not a key") }
    return key
}

func read(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return data
}

let args = Array(CommandLine.arguments.dropFirst())
switch (args.first, args.count) {
case ("keygen", 2):
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    guard FileManager.default.createFile(atPath: args[1], contents: Data((publicKey + "\n").utf8),
                                         attributes: [.posixPermissions: 0o644]) else { fail("cannot write \(args[1])") }
    print(key.rawRepresentation.base64EncodedString())
case ("public", 1):
    print(privateKey().publicKey.rawRepresentation.base64EncodedString())
case ("sign", 3):
    let signature = try privateKey().signature(for: message(version: args[1], archive: read(args[2])))
    print(signature.base64EncodedString())
case ("verify", 5):
    guard let signature = Data(base64Encoded: args[3]), let raw = Data(base64Encoded: args[4]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { exit(1) }
    exit(key.isValidSignature(signature, for: message(version: args[1], archive: read(args[2]))) ? 0 : 1)
default:
    fail("usage: keygen PUBLIC_OUT | public | sign VERSION ARCHIVE | verify VERSION ARCHIVE SIGNATURE PUBLIC_KEY")
}
