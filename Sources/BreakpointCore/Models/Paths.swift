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

    // MARK: ~/Library/Application Support/Breakpoint/

    public var appSupport: URL {
        home.appendingPathComponent("Library/Application Support/Breakpoint", isDirectory: true)
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
    public var cliCopy: URL { binDirectory.appendingPathComponent("breakpoint") }
    public var shellDirectory: URL { dotBreakpoint.appendingPathComponent("shell", isDirectory: true) }
    public var shellZshSnippet: URL { shellDirectory.appendingPathComponent("breakpoint.zsh") }
    public var shellBashSnippet: URL { shellDirectory.appendingPathComponent("breakpoint.bash") }
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
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !trimmed.isEmpty else { return nil }
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// `path` with the home directory replaced by "~".
    public static func abbreviatingHome(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
