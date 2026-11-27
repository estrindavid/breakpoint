import Foundation
#if os(Windows)
import WinSDK
#endif

/// Writes a file through a temporary file in the same directory and `rename`, so readers never see
/// a half-written file (SPEC §5.5).
enum AtomicFile {
    #if os(Windows)
    /// Windows: a new temporary file (`CREATE_NEW`), flushed, then `MoveFileExW` with
    /// `MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH`, which replaces the target in one
    /// step. `mode` has no meaning on NTFS; the file inherits its folder's ACL, as a new file would.
    static func write(_ data: Data, to url: URL, mode: mode_t) throws {
        let directory = url.deletingLastPathComponent()
        let suffix = UUID().uuidString.prefix(8)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).breakpoint-\(suffix).tmp")
        let handle = temp.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw IntegrationError.io("Could not write in \(directory.path) (\(errnoString())).")
        }
        var ok = true
        data.withUnsafeBytes { raw in
            var offset = 0
            while ok, offset < raw.count {
                var written: DWORD = 0
                let chunk = DWORD(min(raw.count - offset, 1 << 30))
                ok = WriteFile(handle, raw.baseAddress! + offset, chunk, &written, nil) && written > 0
                offset += Int(written)
            }
        }
        if ok { ok = FlushFileBuffers(handle) }
        CloseHandle(handle)
        let moved = ok && SafeFile.retryingWhileBusy {
            temp.path.withCString(encodedAs: UTF16.self) { from in
                url.path.withCString(encodedAs: UTF16.self) { to in
                    MoveFileExW(from, to, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
                }
            }
        }
        guard moved else {
            let reason = errnoString()
            _ = temp.path.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
            throw IntegrationError.io("Could not write \(url.path) (\(reason)).")
        }
    }

    /// The last Windows error, in the system's words.
    static func errnoString() -> String { WindowsError.message(GetLastError()) }
    #else
    static func write(_ data: Data, to url: URL, mode: mode_t) throws {
        let directory = url.deletingLastPathComponent()
        let suffix = UUID().uuidString.prefix(8)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).breakpoint-\(suffix).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw IntegrationError.io("Could not write in \(directory.path) (\(errnoString())).") }
        var ok = true
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    ok = false
                    return
                }
                offset += n
            }
        }
        if ok { ok = fchmod(fd, mode) == 0 && fsync(fd) == 0 }
        close(fd)
        guard ok, rename(temp.path, url.path) == 0 else {
            let reason = errnoString()
            unlink(temp.path)
            throw IntegrationError.io("Could not write \(url.path) (\(reason)).")
        }
    }

    static func errnoString() -> String { String(cString: strerror(errno)) }
    #endif

    /// Deletes a file; a file that is already gone is not an error.
    static func remove(_ url: URL) -> Bool {
        #if os(Windows)
        if url.path.withCString(encodedAs: UTF16.self, { DeleteFileW($0) }) { return true }
        let error = GetLastError()
        return error == DWORD(ERROR_FILE_NOT_FOUND) || error == DWORD(ERROR_PATH_NOT_FOUND)
        #else
        return unlink(url.path) == 0 || errno == ENOENT
        #endif
    }
}

/// One configuration file an installer edits: read, back up, re-read, write atomically
/// (SPEC §5.5). Follows symbolic links so dotfiles managed elsewhere stay links.
struct ConfigFile {
    /// The path as configured (may be a symbolic link).
    let url: URL
    let tool: IntegrationID
    let environment: IntegrationEnvironment

    struct Change {
        var file: URL
        var backup: URL?
        var created: Bool
        var deleted: Bool
    }

    /// The file's text, or nil if it does not exist. Throws `.unparseableFile` for text that is
    /// not UTF-8 and `.io` when it cannot be read.
    func read() throws -> String? {
        let target = try resolvedTarget()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { throw IntegrationError.unparseableFile(url, reason: "it is a folder") }
        let data: Data
        do {
            data = try SafeFile.read(target)
        } catch {
            throw IntegrationError.io("\(url.path) could not be read.")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw IntegrationError.unparseableFile(url, reason: "it is not UTF-8 text")
        }
        // Decoded this way a byte-order mark is kept, so it is written back unchanged.
        return String(decoding: data, as: UTF8.self)
    }

    /// Applies `transform` to the current text (nil = absent) and writes the result (nil = delete)
    /// if it differs. Backs the old file up first. Re-reads just before writing and starts again
    /// (up to three times) if the file changed meanwhile. Returns nil when nothing changed.
    @discardableResult
    func update(_ transform: (String?) throws -> String?) throws -> Change? {
        for _ in 0..<3 {
            let original = try read()
            let updated = try transform(original)
            if updated == original { return nil }
            guard try read() == original else { continue }
            let target = try resolvedTarget()
            // Before the backup, so a refused write leaves nothing behind.
            try checkReplaceable(target, exists: original != nil)
            var backup: URL?
            if let original {
                backup = try Backups.save(Data(original.utf8), of: url, tool: tool, environment: environment)
            }
            if let updated {
                try AtomicFile.write(Data(updated.utf8), to: target, mode: existingMode(target) ?? 0o644)
            } else {
                guard AtomicFile.remove(target) else {
                    throw IntegrationError.io("Could not remove \(url.path) (\(AtomicFile.errnoString())).")
                }
            }
            return Change(file: url, backup: backup, created: original == nil, deleted: updated == nil)
        }
        throw IntegrationError.concurrentModification(url)
    }

    /// Refuses (`.io`) to replace a file through a temporary file and `rename` when that would undo
    /// something the user set up: a read-only file (a deliberate lock), a file another user owns
    /// (it would change owner), or a hard-linked file (the other names would keep the old text).
    /// Also refuses up front when the folder is not writable, so no orphan backup is left.
    private func checkReplaceable(_ target: URL, exists: Bool) throws {
        #if os(Windows)
        let shown = PathDisplay.abbreviatingHome(url.path, home: environment.home.path)
        // A rewrite on NTFS never changes the owner (a new file inherits the folder's ACL); the
        // read-only attribute and extra hard links still mean "leave it alone".
        if exists, let info = WindowsFileInfo(path: target.path) {
            if info.isReadOnly {
                throw IntegrationError.io("\(shown) is read-only, so Breakpoint left it alone.")
            }
            if info.links > 1 {
                throw IntegrationError.io("\(shown) has another hard link, so Breakpoint left it alone (rewriting it would split the link).")
            }
        }
        let folder = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw IntegrationError.io("Breakpoint can't write in \(PathDisplay.abbreviatingHome(folder.path, home: environment.home.path)), so nothing was changed.")
        }
        #else
        let shown = PathDisplay.abbreviatingHome(url.path, home: environment.home.path)
        if exists {
            var info = stat()
            if lstat(target.path, &info) == 0 {
                if info.st_uid != geteuid() {
                    throw IntegrationError.io("\(shown) belongs to another user, so Breakpoint left it alone.")
                }
                if access(target.path, W_OK) != 0 {
                    throw IntegrationError.io("\(shown) is read-only, so Breakpoint left it alone.")
                }
                if info.st_nlink > 1 {
                    throw IntegrationError.io("\(shown) has another hard link, so Breakpoint left it alone (rewriting it would split the link).")
                }
            }
        }
        let folder = target.deletingLastPathComponent()
        guard access(folder.path, W_OK) == 0 else {
            throw IntegrationError.io("Breakpoint can't write in \(PathDisplay.abbreviatingHome(folder.path, home: environment.home.path)), so nothing was changed.")
        }
        #endif
    }

    private func existingMode(_ target: URL) -> mode_t? {
        #if os(Windows)
        return nil
        #else
        var info = stat()
        guard stat(target.path, &info) == 0 else { return nil }
        return info.st_mode & 0o7777
        #endif
    }

    /// The final target of `url` after following symbolic links (the path itself if absent).
    func resolvedTarget() throws -> URL {
        var current = url
        for _ in 0..<16 {
            #if os(Windows)
            guard let type = try? FileManager.default.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType,
                  type == .typeSymbolicLink else { return current }
            #else
            var info = stat()
            guard lstat(current.path, &info) == 0 else { return current }
            guard (info.st_mode & S_IFMT) == S_IFLNK else { return current }
            #endif
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else {
                throw IntegrationError.io("\(url.path) is a link that could not be read.")
            }
            current = PathDisplay.isAbsolute(destination)
                ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appendingPathComponent(destination)
            current = current.standardizedFileURL
        }
        throw IntegrationError.io("\(url.path) is a chain of links that never ends.")
    }
}

/// `backups/<tool>-<yyyyMMdd-HHmmss>.<ext>` (SPEC §8), mode 0600 in a 0700 folder.
enum Backups {
    static func save(_ data: Data, of file: URL, tool: IntegrationID, environment: IntegrationEnvironment) throws -> URL {
        let paths = environment.paths
        do {
            try paths.ensureAppSupportDirectory()
            try FileManager.default.createDirectory(at: paths.backupsDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw IntegrationError.io("Could not create the backups folder, so nothing was changed.")
        }
        let ext = fileExtension(file)
        var url = paths.backupFile(tool: tool.rawValue, fileExtension: ext, date: environment.now())
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let base = paths.backupFile(tool: tool.rawValue, fileExtension: "", date: environment.now()).lastPathComponent
            url = paths.backupsDirectory.appendingPathComponent("\(base)-\(counter)" + (ext.isEmpty ? "" : ".\(ext)"))
            counter += 1
        }
        do {
            try AtomicFile.write(data, to: url, mode: 0o600)
        } catch {
            throw IntegrationError.io("Could not back up \(file.lastPathComponent), so nothing was changed.")
        }
        return url
    }

    /// "json" for settings.json, "zshrc" for .zshrc, "bash_profile" for .bash_profile.
    static func fileExtension(_ file: URL) -> String {
        if !file.pathExtension.isEmpty { return file.pathExtension }
        let name = file.lastPathComponent
        return name.hasPrefix(".") ? String(name.dropFirst()) : name
    }
}

/// What Breakpoint created so uninstall can leave things exactly as they were:
/// `~/Library/Application Support/Breakpoint/integrations.json`.
///
/// - `files[path].original`: recorded at install when the file was absent or had no content of its
///   own (empty, blank, `{}`); `hasOriginal` tells "absent" (nil) from "not recorded". On uninstall,
///   if nothing but Breakpoint's own skeleton is left, the original is put back (or the file
///   deleted).
/// - `files[path].keepEmpty`: JSON containers ("hooks", "hooks/Stop") that existed, empty, before
///   Breakpoint added to them; uninstall leaves them in place instead of removing them as empty.
/// - `directories`: folders Breakpoint created inside a tool's folder, removed when empty.
struct IntegrationLedger: Codable, Equatable {
    struct FileRecord: Codable, Equatable {
        var hasOriginal = false
        var original: String?
        var keepEmpty: [String] = []
    }

    var files: [String: FileRecord] = [:]
    var directories: [String] = []

    static func url(_ paths: BreakpointPaths) -> URL { paths.appSupport.appendingPathComponent("integrations.json") }

    static func load(_ paths: BreakpointPaths) -> IntegrationLedger {
        (try? JSONFile<IntegrationLedger>(url: url(paths)).read()) ?? IntegrationLedger()
    }

    func save(_ paths: BreakpointPaths) {
        let file = JSONFile<IntegrationLedger>(url: Self.url(paths))
        if files.isEmpty && directories.isEmpty {
            try? FileManager.default.removeItem(at: file.url)
        } else {
            try? file.write(self)
        }
    }

    /// Read-modify-write under an exclusive lock (`integrations.lock`), so the app and the CLI, or
    /// two installs running at once, never lose each other's records. Not reentrant: `body` must
    /// not update the ledger itself.
    static func update(_ paths: BreakpointPaths, _ body: (inout IntegrationLedger) -> Void) {
        try? paths.ensureAppSupportDirectory()
        let lock = FileLock(paths.appSupport.appendingPathComponent("integrations.lock"))
        defer { lock.unlock() }
        var ledger = load(paths)
        let before = ledger
        body(&ledger)
        if ledger != before { ledger.save(paths) }
    }
}

extension ConfigFile {
    /// The ledger's record for this file, if any.
    func ledgerRecord() -> IntegrationLedger.FileRecord? {
        IntegrationLedger.load(environment.paths).files[url.path]
    }

    /// Records the file's original text (nil = absent) unless one is recorded already.
    func remember(original: String?) {
        IntegrationLedger.update(environment.paths) { ledger in
            var record = ledger.files[url.path] ?? .init()
            if !record.hasOriginal {
                record.hasOriginal = true
                record.original = original
            }
            ledger.files[url.path] = record
        }
    }

    /// Records containers that were empty before Breakpoint added to them.
    func remember(keepEmpty paths: [String]) {
        guard !paths.isEmpty else { return }
        IntegrationLedger.update(environment.paths) { ledger in
            var record = ledger.files[url.path] ?? .init()
            for path in paths where !record.keepEmpty.contains(path) { record.keepEmpty.append(path) }
            ledger.files[url.path] = record
        }
    }

    func forgetRecord() {
        IntegrationLedger.update(environment.paths) { $0.files[url.path] = nil }
    }
}

/// Folders Breakpoint creates inside a tool's folder.
enum CreatedDirectory {
    /// Creates `url` (and parents) if missing, recording each folder it made in the ledger.
    static func ensure(_ url: URL, environment: IntegrationEnvironment, mode: Int = 0o755) throws {
        let fm = FileManager.default
        var missing: [URL] = []
        var current = url.standardizedFileURL
        while !fm.fileExists(atPath: current.path), current.path != "/" {
            missing.append(current)
            current = current.deletingLastPathComponent()
        }
        guard !missing.isEmpty else { return }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: mode])
        } catch {
            throw IntegrationError.io("Could not create \(url.path).")
        }
        IntegrationLedger.update(environment.paths) { ledger in
            for dir in missing where !ledger.directories.contains(dir.path) { ledger.directories.append(dir.path) }
        }
    }

    /// Removes `url` (then its recorded parents) if Breakpoint created it and it is now empty.
    static func removeIfEmpty(_ url: URL, environment: IntegrationEnvironment) {
        let fm = FileManager.default
        var current = url.standardizedFileURL
        while true {
            let ledger = IntegrationLedger.load(environment.paths)
            guard ledger.directories.contains(current.path) else { return }
            if fm.fileExists(atPath: current.path) {
                guard let contents = try? fm.contentsOfDirectory(atPath: current.path), contents.isEmpty else { return }
                guard FileSystemShim.removeEmptyDirectory(current) else { return }
            }
            IntegrationLedger.update(environment.paths) { $0.directories.removeAll { $0 == current.path } }
            current = current.deletingLastPathComponent()
        }
    }
}
