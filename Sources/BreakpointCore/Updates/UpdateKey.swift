import Foundation

/// The release key's public half (SPEC §2.11): every update archive must carry a valid Ed25519
/// signature made with the matching private key, which lives only in the repository's GitHub
/// Actions secret `UPDATE_SIGNING_KEY`. `scripts/release-keygen.sh` writes the line below; commit it.
///
/// `nil` (no key yet): this copy only tells you about new versions and opens the download page; it
/// never installs one. See docs/RELEASING.md for what to do if the key is lost or leaks.
public enum UpdateKey {
    public static let publicKeyBase64: String? = nil // written by scripts/release-keygen.sh
}
