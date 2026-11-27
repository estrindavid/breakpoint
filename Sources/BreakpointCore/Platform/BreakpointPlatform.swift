import Foundation

/// The few words and facts that differ between the macOS and Windows apps. Everything else in Core
/// is the same on both.
public enum BreakpointPlatform {
    public static var isWindows: Bool {
        #if os(Windows)
        true
        #else
        false
        #endif
    }

    /// "Mac" or "PC", as in "not found on this Mac".
    public static var computerName: String { isWindows ? "PC" : "Mac" }

    /// Where the app keeps its data, as the person would find it ("~/Library/Application Support/
    /// Breakpoint" or "%LOCALAPPDATA%\Breakpoint").
    public static var dataFolderDisplayName: String {
        isWindows ? "%LOCALAPPDATA%\\Breakpoint" : "~/Library/Application Support/Breakpoint"
    }
}

/// Whether a file is a program the system will run: executable on macOS; on Windows (which has no
/// executable bit) a file that starts with the PE signature `MZ`.
public enum Executable {
    public static func isRunnable(_ url: URL) -> Bool {
        #if os(Windows)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 2)) ?? Data()
        return head == Data("MZ".utf8)
        #else
        return FileManager.default.isExecutableFile(atPath: url.path)
        #endif
    }
}
