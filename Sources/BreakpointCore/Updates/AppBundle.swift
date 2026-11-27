import Foundation
#if os(Windows)
import WinSDK
#endif

/// What an installed copy of the app looks like on disk, and the few system calls an in-place
/// update needs (SPEC §2.11), per platform. `UpdateInstaller` and `UpdateRelauncher` use only these.
///
/// - macOS: `Breakpoint.app`, its `Contents/Info.plist`, `ditto` to unpack, `renamex_np(RENAME_SWAP)`
///   to exchange two bundles in one step, the quarantine attribute, `open -g`, signals.
/// - Windows: the folder `Breakpoint` (by default `%LOCALAPPDATA%\Programs\Breakpoint`) holding
///   `Breakpoint.exe`, `bin\breakpoint.exe` and `breakpoint-app.json` (identifier, version,
///   executable: the Info.plist of this platform); `tar.exe` (in every Windows 10 and later) to
///   unpack. Windows cannot rename a folder while a program inside it runs, but it can rename the
///   running program's files, so the exchange swaps the two folders' *contents*, item by item,
///   with every step undone if one fails.
public enum AppBundle {
    /// The manifest in a Windows app folder.
    public static let manifestName = "breakpoint-app.json"

    /// Whether `url` names an app bundle (by its name; the contents are checked separately).
    public static func isApp(_ url: URL) -> Bool {
        #if os(Windows)
        return url.standardizedFileURL.lastPathComponent.lowercased() == "breakpoint"
        #else
        return url.pathExtension == "app"
        #endif
    }

    /// The bundle's executable for `info`.
    public static func executable(_ app: URL, _ info: UpdateInstaller.BundleInfo) -> URL {
        #if os(Windows)
        return app.appendingPathComponent(info.executable)
        #else
        return app.appendingPathComponent("Contents/MacOS/\(info.executable)")
        #endif
    }

    public static func bundleInfo(_ app: URL) -> UpdateInstaller.BundleInfo? {
        #if os(Windows)
        guard let data = try? Data(contentsOf: app.appendingPathComponent(manifestName)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let identifier = object["identifier"] as? String,
              let version = object["version"] as? String,
              let executable = object["executable"] as? String,
              !executable.contains("/"), !executable.contains("\\") else { return nil }
        return UpdateInstaller.BundleInfo(identifier: identifier, version: version, executable: executable)
        #else
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              let version = plist["CFBundleShortVersionString"] as? String,
              let executable = plist["CFBundleExecutable"] as? String,
              !executable.contains("/") else { return nil }
        return UpdateInstaller.BundleInfo(identifier: identifier, version: version, executable: executable)
        #endif
    }

    /// The Windows manifest's text for a build (written by `scripts/windows/package.ps1`).
    public static func manifest(identifier: String, version: String, executable: String) -> String {
        "{\n  \"identifier\": \"\(identifier)\",\n  \"version\": \"\(version)\",\n  \"executable\": \"\(executable)\"\n}\n"
    }

    /// macOS: the `com.apple.quarantine` attribute. Windows: never (the app downloads its own
    /// updates; nothing marks them).
    public static func isQuarantined(_ url: URL) -> Bool {
        #if os(Windows)
        return false
        #else
        return getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
        #endif
    }

    /// A directory, not a symbolic link (or junction) to one.
    public static func isRealFolder(_ url: URL) -> Bool {
        #if os(Windows)
        let attributes = url.path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
        return attributes != INVALID_FILE_ATTRIBUTES
            && attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
            && attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
        #else
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        #endif
    }

    /// Exchanges `a` and `b`: afterwards each holds what the other held.
    public static func exchange(_ a: URL, _ b: URL) throws {
        #if os(Windows)
        try exchangeContents(a, b)
        #else
        guard renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateInstallError.swapFailed(String(cString: strerror(errno)))
        }
        #endif
    }

    /// Unpacks a zip into a folder: `ditto -x -k` on macOS (a quarantined zip passes its
    /// quarantine on, and `checkBundle` then refuses it), `tar -x -f` on Windows.
    public static func unpack(_ archive: URL, _ folder: URL) throws {
        let process = Process()
        #if os(Windows)
        let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        process.executableURL = URL(fileURLWithPath: root).appendingPathComponent("System32/tar.exe")
        process.arguments = ["-x", "-f", PathDisplay.native(archive), "-C", PathDisplay.native(folder)]
        let tool = "tar"
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, folder.path]
        let tool = "ditto"
        #endif
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateInstallError.unpackFailed("\(tool) exited \(process.terminationStatus)")
        }
    }

    // MARK: Processes (the relaunch helper)

    public static func isAlive(_ pid: Int32) -> Bool {
        #if os(Windows)
        guard pid > 0, let process = OpenProcess(DWORD(SYNCHRONIZE), false, DWORD(pid)) else { return false }
        defer { CloseHandle(process) }
        return WaitForSingleObject(process, 0) == DWORD(WAIT_TIMEOUT)
        #else
        return kill(pid, 0) == 0
        #endif
    }

    /// Starts the app in the background: `open -g` on macOS; on Windows the executable, detached.
    public static func open(_ app: URL) throws {
        #if os(Windows)
        guard let info = bundleInfo(app) else { throw UpdateInstallError.didNotStart }
        let process = Process()
        process.executableURL = executable(app, info)
        process.arguments = []
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateInstallError.didNotStart
        }
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", app.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateInstallError.didNotStart }
        #endif
    }

    /// Asks the process to quit, then ends it two seconds later if it is still there.
    /// macOS: SIGTERM, then SIGKILL. Windows: a quit request through the app's socket is not
    /// available to the helper, so it waits, then `TerminateProcess`.
    public static func stop(_ pid: Int32) {
        #if os(Windows)
        guard let process = OpenProcess(DWORD(PROCESS_TERMINATE | SYNCHRONIZE), false, DWORD(pid)) else { return }
        defer { CloseHandle(process) }
        if WaitForSingleObject(process, 2000) == DWORD(WAIT_TIMEOUT) {
            _ = TerminateProcess(process, 1)
        }
        #else
        kill(pid, SIGTERM)
        for _ in 0..<20 where kill(pid, 0) == 0 { Thread.sleep(forTimeInterval: 0.1) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        #endif
    }

    #if os(Windows)
    /// Swaps the contents of two folders on the same volume, item by item, through a third
    /// folder beside `a`. On any failure every move made so far is undone in reverse order.
    static func exchangeContents(_ a: URL, _ b: URL) throws {
        let fm = FileManager.default
        let holding = a.deletingLastPathComponent().appendingPathComponent(".swap-" + UUID().uuidString.prefix(8), isDirectory: true)
        do {
            try fm.createDirectory(at: holding, withIntermediateDirectories: false)
        } catch {
            throw UpdateInstallError.swapFailed("could not create \(holding.lastPathComponent)")
        }
        var done: [(from: URL, to: URL)] = []
        func move(_ from: URL, _ to: URL) throws {
            let ok = PathDisplay.native(from).withCString(encodedAs: UTF16.self) { source in
                PathDisplay.native(to).withCString(encodedAs: UTF16.self) { target in
                    MoveFileExW(source, target, DWORD(MOVEFILE_WRITE_THROUGH))
                }
            }
            guard ok else { throw UpdateInstallError.swapFailed(WindowsError.message(GetLastError())) }
            done.append((from, to))
        }
        do {
            let inB = try fm.contentsOfDirectory(at: b, includingPropertiesForKeys: nil)
            let inA = try fm.contentsOfDirectory(at: a, includingPropertiesForKeys: nil)
            for item in inB { try move(item, holding.appendingPathComponent(item.lastPathComponent)) }
            for item in inA { try move(item, b.appendingPathComponent(item.lastPathComponent)) }
            for item in inB { try move(holding.appendingPathComponent(item.lastPathComponent), a.appendingPathComponent(item.lastPathComponent)) }
        } catch {
            for step in done.reversed() {
                _ = PathDisplay.native(step.to).withCString(encodedAs: UTF16.self) { source in
                    PathDisplay.native(step.from).withCString(encodedAs: UTF16.self) { target in
                        MoveFileExW(source, target, DWORD(MOVEFILE_WRITE_THROUGH))
                    }
                }
            }
            try? fm.removeItem(at: holding)
            throw (error as? UpdateInstallError) ?? UpdateInstallError.swapFailed("\(error)")
        }
        try? fm.removeItem(at: holding)
    }
    #endif
}
