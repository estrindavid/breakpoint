import Foundation

/// Decides where the socket lives, identically for the app and the CLI (SPEC §5.1).
///
/// `~/Library/Application Support/Breakpoint/breakpoint.sock`, unless that path is longer than
/// 103 bytes (the `sun_path` limit minus the terminator), in which case `~/.breakpoint/run/bp.sock`.
public struct SocketPath: Equatable, Hashable, Sendable {
    /// Maximum UTF-8 length of a usable socket path.
    public static let maxBytes = 103

    public let url: URL
    /// True when the fallback location is used.
    public let isFallback: Bool

    public init(paths: BreakpointPaths) {
        let preferred = paths.preferredSocketFile
        if preferred.path.utf8.count <= Self.maxBytes {
            url = preferred
            isFallback = false
        } else {
            url = paths.fallbackSocketFile
            isFallback = true
        }
    }

    public var path: String { url.path }

    /// The directory holding the socket (created mode 0700 by the server).
    public var directory: URL { url.deletingLastPathComponent() }
}

extension SocketPath {
    /// Something is at the socket path (a socket file, or whatever else is in the way). Unlike
    /// `FileManager.fileExists`, this sees a Windows AF_UNIX socket file too.
    public var exists: Bool { UnixSocket.socketFileExists(path) }
}

extension SocketPath {
    /// What is at the socket path is a socket file (macOS: `S_IFSOCK`; Windows: an AF_UNIX
    /// reparse point).
    public var isSocketFile: Bool { UnixSocket.isSocketFile(path) }
}
