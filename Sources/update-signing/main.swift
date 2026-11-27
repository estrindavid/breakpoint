import BreakpointCore
import Foundation

// The release key's tool, built from Core's own signature code, for platforms without CryptoKit
// (Windows; macOS uses scripts/update-signing.swift). Same commands and output:
//
//   keygen PUBLIC_OUT            new key pair: the private key (base64) to stdout, never to disk;
//                                the public key (base64) to the file PUBLIC_OUT
//   public                       the public key of the private key in $UPDATE_SIGNING_KEY
//   sign VERSION ARCHIVE         the signature (base64) of ARCHIVE as VERSION, with $UPDATE_SIGNING_KEY
//   verify VERSION ARCHIVE SIGNATURE PUBLIC_KEY   exit 0 if it verifies, 1 if not
//
// scripts/e2e.sh uses it on Windows with throwaway keys made on the spot. Never create or commit a
// real key with it: scripts/release-keygen.sh is for the maintainer who publishes releases.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

func privateKey() -> UpdateSigningKey {
    guard let base64 = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"], !base64.isEmpty else {
        fail("UPDATE_SIGNING_KEY is not set")
    }
    guard let raw = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = UpdateSigningKey(rawRepresentation: raw) else { fail("UPDATE_SIGNING_KEY is not a key") }
    return key
}

func read(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return data
}

let args = Array(CommandLine.arguments.dropFirst())
switch (args.first, args.count) {
case ("keygen", 2):
    let key = UpdateSigningKey()
    guard FileManager.default.createFile(atPath: args[1], contents: Data((key.publicKeyBase64 + "\n").utf8)) else {
        fail("cannot write \(args[1])")
    }
    print(key.rawRepresentation.base64EncodedString())
case ("public", 1):
    print(privateKey().publicKeyBase64)
case ("sign", 3):
    print(try UpdateSignature.sign(version: args[1], archive: read(args[2]), privateKey: privateKey()))
case ("verify", 5):
    let archive = read(args[2])
    exit(UpdateSignature.isValid(signature: args[3], version: args[1], size: archive.count,
                                 sha256: UpdateSignature.sha256Hex(archive), publicKeyBase64: args[4]) ? 0 : 1)
default:
    fail("usage: keygen PUBLIC_OUT | public | sign VERSION ARCHIVE | verify VERSION ARCHIVE SIGNATURE PUBLIC_KEY")
}
