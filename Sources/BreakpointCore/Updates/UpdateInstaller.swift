import Foundation

// Installing an update in place (SPEC §2.11), without Apple signing and without third-party code:
//
// 1. `UpdateLocation`: is this copy somewhere it can replace itself?
// 2. `UpdateInstaller.verify`: the downloaded archive's size, SHA-256 and Ed25519 signature
//    (over version, size and hash), and that the version is newer, before anything is unpacked.
// 3. `stage`: unpack with ditto next to the installed app (same folder, so the swap is one
//    rename), then check the bundle inside: one app, our bundle identifier, the signed version, an
//    executable, and no quarantine.
// 4. `swap`: exchange the two bundles atomically (`renamex_np(RENAME_SWAP)`); the old one stays,
//    whole, in the staging folder until the new one has started.
// 5. `UpdateRelauncher` (run by the old copy's `breakpoint update-relaunch`): start the new copy,
//    wait for it to confirm, and swap back if it does not.

/// Why this copy cannot replace itself.
public enum UpdateLocationBlocker: Equatable, Sendable {
    /// Not running from an app bundle (a development build in `.build/`).
    case notAnApp
    /// macOS runs it from a temporary read-only copy (App Translocation), which happens to a
    /// quarantined app opened where it was downloaded.
    case translocated
    /// The app or its folder cannot be changed by this user (e.g. /Applications for a standard user).
    case readOnly(folder: String)

    public var explanation: String {
        switch self {
        case .notAnApp:
            return "This is a development build, so it can't replace itself."
        case .translocated:
            return "macOS is running Breakpoint from a temporary copy. Move it to Applications and open it again to install updates."
        case .readOnly(let folder):
            return "Breakpoint can't change \(folder). Install the new version with the install command, or move Breakpoint to a folder you own."
        }
    }
}

public enum UpdateLocation {
    /// `nil` when the app at `app` can be replaced in place.
    public static func blocker(for app: URL, fileManager: FileManager = .default) -> UpdateLocationBlocker? {
        let path = app.standardizedFileURL.path
        guard app.pathExtension == "app" else { return .notAnApp }
        if path.contains("/AppTranslocation/") { return .translocated }
        let folder = app.deletingLastPathComponent().path
        guard fileManager.isWritableFile(atPath: folder), fileManager.isWritableFile(atPath: path) else {
            return .readOnly(folder: PathDisplay.abbreviatingHome(folder, home: NSHomeDirectory()))
        }
        return nil
    }
}

/// Why an install stopped. Every case leaves the installed app untouched (or puts it back).
public enum UpdateInstallError: Error, Equatable, Sendable {
    case noKey
    case notInstallable
    case notNewer(String)
    case download(String)
    case sizeMismatch
    case checksumMismatch
    case badSignature
    case unpackFailed(String)
    case wrongContents
    case wrongBundle(String)
    case quarantined
    case blocked(UpdateLocationBlocker)
    case breakInProgress
    case swapFailed(String)
    case didNotStart

    /// One plain sentence for the card and About.
    public var explanation: String {
        switch self {
        case .noKey, .notInstallable: return "This version can only be installed from its download page."
        case .notNewer: return "The download is not newer than this version, so Breakpoint left it."
        case .download: return "The download didn't finish."
        case .sizeMismatch, .checksumMismatch, .badSignature:
            return "The download didn't match its signature, so Breakpoint didn't install it."
        case .unpackFailed, .wrongContents, .wrongBundle: return "The download didn't contain the expected app."
        case .quarantined: return "macOS marked the download as quarantined, so Breakpoint didn't install it."
        case .blocked(let blocker): return blocker.explanation
        case .breakInProgress: return "A break started, so the update waits. Try again after it."
        case .swapFailed: return "Breakpoint couldn't replace itself."
        case .didNotStart: return "The new version didn't start, so Breakpoint went back to this one."
        }
    }
}

/// An update unpacked next to the installed app, checked, not yet swapped in.
public struct StagedUpdate: Equatable, Sendable {
    /// `<folder>/.Breakpoint-update-<id>/`: everything here is removed when the update ends.
    public let stagingDirectory: URL
    public let app: URL
    public let version: String
}

/// After the swap: the new app is at `installed`, the old one at `backup` (inside the staging folder).
public struct SwappedUpdate: Codable, Equatable, Sendable {
    public let installed: URL
    public let backup: URL
    public let stagingDirectory: URL
}

public struct UpdateInstaller {
    public static let stagingPrefix = ".Breakpoint-update-"

    public let installedApp: URL
    public let bundleIdentifier: String
    public let current: SemanticVersion
    public let publicKeyBase64: String?
    /// Unpacks a zip into a folder (`/usr/bin/ditto -x -k`; injectable for tests).
    public var unpack: (URL, URL) throws -> Void

    public init(installedApp: URL, bundleIdentifier: String = BreakpointVersion.bundleIdentifier,
                current: SemanticVersion = .current, publicKeyBase64: String? = UpdateKey.publicKeyBase64,
                unpack: @escaping (URL, URL) throws -> Void = UpdateInstaller.ditto) {
        self.installedApp = installedApp.standardizedFileURL
        self.bundleIdentifier = bundleIdentifier
        self.current = current
        self.publicKeyBase64 = publicKeyBase64
        self.unpack = unpack
    }

    /// Checks the archive before anything is unpacked: a key, a complete feed entry, a newer
    /// version, then size, SHA-256 and the signature over version, size and SHA-256.
    public func verify(archive: URL, release: UpdateRelease) throws {
        guard UpdateSignature.publicKey(publicKeyBase64) != nil else { throw UpdateInstallError.noKey }
        guard let size = release.size, let sha256 = release.sha256, let signature = release.signature else {
            throw UpdateInstallError.notInstallable
        }
        guard let version = release.semanticVersion, version > current else {
            throw UpdateInstallError.notNewer(release.version)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: archive.path)
        guard let actual = (attributes?[.size] as? NSNumber)?.intValue, actual == size,
              size <= UpdateFeed.maximumArchiveSize else { throw UpdateInstallError.sizeMismatch }
        let data: Data
        do {
            data = try Data(contentsOf: archive, options: .mappedIfSafe)
        } catch {
            throw UpdateInstallError.download("\(error)")
        }
        guard UpdateSignature.sha256Hex(data) == sha256.lowercased() else { throw UpdateInstallError.checksumMismatch }
        guard UpdateSignature.isValid(signature: signature, version: release.version, size: size, sha256: sha256,
                                      publicKeyBase64: publicKeyBase64) else { throw UpdateInstallError.badSignature }
    }

    /// Verifies, then unpacks next to the installed app and checks the bundle inside.
    public func stage(archive: URL, release: UpdateRelease) throws -> StagedUpdate {
        if let blocker = UpdateLocation.blocker(for: installedApp) { throw UpdateInstallError.blocked(blocker) }
        try verify(archive: archive, release: release)
        let fm = FileManager.default
        let staging = installedApp.deletingLastPathComponent()
            .appendingPathComponent(Self.stagingPrefix + UUID().uuidString.prefix(8), isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try unpack(archive, staging)
        } catch let error as UpdateInstallError {
            try? fm.removeItem(at: staging)
            throw error
        } catch {
            try? fm.removeItem(at: staging)
            throw UpdateInstallError.unpackFailed("\(error)")
        }
        do {
            let items = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
            guard items.count == 1, let app = items.first, app.pathExtension == "app", Self.isRealFolder(app) else {
                throw UpdateInstallError.wrongContents
            }
            try checkBundle(app, version: release.version)
            return StagedUpdate(stagingDirectory: staging, app: app, version: release.version)
        } catch {
            try? fm.removeItem(at: staging)
            throw (error as? UpdateInstallError) ?? UpdateInstallError.wrongContents
        }
    }

    /// Our bundle identifier, the signed version, an executable, and no quarantine.
    public func checkBundle(_ app: URL, version: String) throws {
        guard let info = Self.bundleInfo(app) else { throw UpdateInstallError.wrongBundle("no Info.plist") }
        guard info.identifier == bundleIdentifier else { throw UpdateInstallError.wrongBundle("identifier \(info.identifier)") }
        guard info.version == version else { throw UpdateInstallError.wrongBundle("version \(info.version)") }
        let executable = app.appendingPathComponent("Contents/MacOS/\(info.executable)")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UpdateInstallError.wrongBundle("no executable")
        }
        if Self.isQuarantined(app) || Self.isQuarantined(executable) { throw UpdateInstallError.quarantined }
    }

    /// Exchanges the staged app and the installed one in one step. Afterwards the new app is at
    /// `installedApp` and the old one, whole, at the staged path.
    public func swap(_ staged: StagedUpdate) throws -> SwappedUpdate {
        try Self.exchange(staged.app, installedApp)
        return SwappedUpdate(installed: installedApp, backup: staged.app, stagingDirectory: staged.stagingDirectory)
    }

    /// Puts the old app back (the failed new one goes to the staging folder) and removes the folder.
    /// Refuses a record (`pending-update.json`, read back by the relaunch helper) that does not
    /// describe a swap this installer made, so a damaged file can never move or delete anything else.
    public static func rollback(_ swapped: SwappedUpdate) throws {
        guard isOwnSwap(swapped) else { throw UpdateInstallError.swapFailed("not an update's staging folder") }
        try exchange(swapped.backup, swapped.installed)
        try? FileManager.default.removeItem(at: swapped.stagingDirectory)
    }

    /// Removes the staging folder (the old app, once the new one runs).
    public static func finish(_ swapped: SwappedUpdate) {
        guard isOwnSwap(swapped) else { return }
        try? FileManager.default.removeItem(at: swapped.stagingDirectory)
    }

    /// The shape `swap` leaves: `<folder>/.Breakpoint-update-<id>/` next to the installed app,
    /// holding the backup, an `.app` directly inside it.
    static func isOwnSwap(_ swapped: SwappedUpdate) -> Bool {
        let staging = swapped.stagingDirectory.standardizedFileURL
        let installed = swapped.installed.standardizedFileURL
        let backup = swapped.backup.standardizedFileURL
        return staging.isFileURL && installed.isFileURL && backup.isFileURL
            && staging.lastPathComponent.hasPrefix(stagingPrefix)
            && staging.deletingLastPathComponent().path == installed.deletingLastPathComponent().path
            && backup.deletingLastPathComponent().path == staging.path
            && installed.pathExtension == "app" && backup.pathExtension == "app"
    }

    /// A directory, not a symbolic link to one.
    static func isRealFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Removes staging folders left next to the app by an update that was interrupted.
    public static func cleanUpLeftovers(nextTo app: URL, except keep: URL? = nil) {
        let fm = FileManager.default
        let folder = app.deletingLastPathComponent()
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix(stagingPrefix)
            && item.standardizedFileURL != keep?.standardizedFileURL {
            try? fm.removeItem(at: item)
        }
    }

    // MARK: Helpers

    public struct BundleInfo: Equatable, Sendable {
        public let identifier: String
        public let version: String
        public let executable: String
    }

    public static func bundleInfo(_ app: URL) -> BundleInfo? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              let version = plist["CFBundleShortVersionString"] as? String,
              let executable = plist["CFBundleExecutable"] as? String,
              !executable.contains("/") else { return nil }
        return BundleInfo(identifier: identifier, version: version, executable: executable)
    }

    public static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    static func exchange(_ a: URL, _ b: URL) throws {
        guard renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateInstallError.swapFailed(String(cString: strerror(errno)))
        }
    }

    /// `/usr/bin/ditto -x -k ARCHIVE FOLDER`. A zip that is not quarantined unpacks without
    /// quarantine; a quarantined one passes it on (and `checkBundle` then refuses it).
    public static func ditto(_ archive: URL, _ folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateInstallError.unpackFailed("ditto exited \(process.terminationStatus)")
        }
    }
}
