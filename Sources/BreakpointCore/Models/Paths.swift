import Foundation

/// Every file location Breakpoint uses (SPEC §8), derived from an injectable home directory.
///
/// Production code uses `BreakpointPaths.live()`; tests and previews pass a temporary directory so
/// they never touch the real home folder. Nothing here creates files except
/// `ensureDirectories()`.
public struct BreakpointPaths: Equatable, Hashable, Sendable {
    /// The (possibly fake) user home directory.
    public let home: URL

    public init(home: URL) {
        self.home = home.standardizedFileURL
    }

    /// Environment variable that overrides the home directory for the app and the CLI
    /// (development and manual testing only; never set in production).
    public static let homeOverrideVariable = "BREAKPOINT_HOME"

    /// The real home directory, or `$BREAKPOINT_HOME` when set.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> BreakpointPaths {
        if let override = environment[homeOverrideVariable], !override.isEmpty {
            return BreakpointPaths(home: URL(fileURLWithPath: override, isDirectory: true))
        }
        return BreakpointPaths(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: ~/Library/Application Support/Breakpoint/ (Windows: %LOCALAPPDATA%\Breakpoint\)

    /// The app's data folder (SPEC §8). macOS: `~/Library/Application Support/Breakpoint`.
    /// Windows: `~\AppData\Local\Breakpoint` (the machine's own data, never roamed, as
    /// Application Support is never synced), under `$BREAKPOINT_HOME` when that is set.
    public var appSupport: URL {
        home.appendingPathComponent(Self.appSupportRelativePath, isDirectory: true)
    }

    /// `appSupport` relative to the home folder, as scripts write it.
    public static var appSupportRelativePath: String {
        #if os(Windows)
        "AppData/Local/Breakpoint"
        #else
        "Library/Application Support/Breakpoint"
        #endif
    }

    /// The CLI's file name: `breakpoint`, or `breakpoint.exe` on Windows.
    public static var cliFileName: String {
        #if os(Windows)
        "breakpoint.exe"
        #else
        "breakpoint"
        #endif
    }
    public var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }
    public var historyFile: URL { appSupport.appendingPathComponent("history.jsonl") }
    /// Run-length estimator state.
    public var sessionsFile: URL { appSupport.appendingPathComponent("sessions.json") }
    /// Which routine and copy variants come next (SPEC §2.2).
    public var rotationFile: URL { appSupport.appendingPathComponent("rotation.json") }
    /// Preferred socket location (see `SocketPath` for the length fallback).
    public var preferredSocketFile: URL { appSupport.appendingPathComponent("breakpoint.sock") }
    public var watchdogLog: URL { appSupport.appendingPathComponent("watchdog.log") }
    /// The update check's memory: last check, newest release seen, "Later" (SPEC §2.11).
    public var updatesFile: URL { appSupport.appendingPathComponent("updates.json") }
    /// An in-place update between the old copy quitting and the new one confirming it started.
    public var pendingUpdateFile: URL { appSupport.appendingPathComponent("pending-update.json") }
    public var backupsDirectory: URL { appSupport.appendingPathComponent("backups", isDirectory: true) }

    // MARK: ~/.breakpoint/

    public var dotBreakpoint: URL { home.appendingPathComponent(".breakpoint", isDirectory: true) }
    public var binDirectory: URL { dotBreakpoint.appendingPathComponent("bin", isDirectory: true) }
    /// The CLI copy every hook calls (SPEC §5.2).
    public var cliCopy: URL { binDirectory.appendingPathComponent(Self.cliFileName) }
    public var shellDirectory: URL { dotBreakpoint.appendingPathComponent("shell", isDirectory: true) }
    public var shellZshSnippet: URL { shellDirectory.appendingPathComponent("breakpoint.zsh") }
    public var shellBashSnippet: URL { shellDirectory.appendingPathComponent("breakpoint.bash") }
    /// The PowerShell snippet (Windows), dot-sourced from a marker block in the profile.
    public var shellPowerShellSnippet: URL { shellDirectory.appendingPathComponent("breakpoint.ps1") }
    /// Socket fallback directory (only when the preferred path is too long).
    public var runDirectory: URL { dotBreakpoint.appendingPathComponent("run", isDirectory: true) }
    public var fallbackSocketFile: URL { runDirectory.appendingPathComponent("bp.sock") }

    /// `backups/<tool>-<yyyyMMdd-HHmmss>.<ext>` (SPEC §8). Uses local time.
    public func backupFile(tool: String, fileExtension: String, date: Date, timeZone: TimeZone = .current) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let ext = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        return backupsDirectory.appendingPathComponent("\(tool)-\(formatter.string(from: date))\(ext)")
    }

    /// Creates the Application Support folder (mode 0700) if needed. Call before writing any file.
    public func ensureAppSupportDirectory(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
    }
}

/// Display helpers for paths.
public enum PathDisplay {
    /// Last path component of `path` ("breakpoint" for "/Users/x/breakpoint/"); `nil` for empty or "/".
    public static func folderName(_ path: String) -> String? {
        #if os(Windows)
        // Either separator, and a bare drive ("C:\") has no folder name.
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") { trimmed.removeLast() }
        guard !trimmed.isEmpty, !(trimmed.count == 2 && trimmed.hasSuffix(":")) else { return nil }
        let name = lastComponent(trimmed)
        return name.isEmpty || name == "/" || name == "\\" ? nil : name
        #else
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !trimmed.isEmpty else { return nil }
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
        #endif
    }

    /// The last component of a path: after the last `/` (on Windows, `/` or `\`).
    public static func lastComponent(_ path: String) -> String {
        #if os(Windows)
        guard let separator = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return path }
        let rest = path[path.index(after: separator)...]
        return rest.isEmpty ? path : String(rest)
        #else
        return (path as NSString).lastPathComponent
        #endif
    }

    /// The path as the system writes it: `/Users/x/…` on macOS, `C:\Users\x\…` on Windows.
    public static func native(_ url: URL) -> String {
        #if os(Windows)
        return url.withUnsafeFileSystemRepresentation { pointer in
            pointer.map { String(cString: $0) } ?? url.path
        }.replacingOccurrences(of: "/", with: "\\")
        #else
        return url.path
        #endif
    }

    /// An absolute path: `/…`, or on Windows also `C:/…`, `C:\…` and `\\server\…`.
    public static func isAbsolute(_ path: String) -> Bool {
        if path.hasPrefix("/") { return true }
        #if os(Windows)
        if path.hasPrefix("\\\\") { return true }
        let scalars = Array(path.unicodeScalars.prefix(3))
        if scalars.count == 3, scalars[0].isASCII, CharacterSet.letters.contains(scalars[0]), scalars[1] == ":", scalars[2] == "/" || scalars[2] == "\\" {
            return true
        }
        #endif
        return false
    }

    /// `path` with the home directory replaced by "~".
    public static func abbreviatingHome(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
