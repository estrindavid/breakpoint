import Foundation
import Testing
@testable import BreakpointCore

/// Fake app bundles and archives in a temporary folder, signed with a throwaway key made here.
struct UpdateFixture {
    let dir = TemporaryDirectory()
    let key = UpdateSigningKey()
    var publicKey: String { key.publicKeyBase64 }
    static let page = URL(string: "https://github.com/estrindavid/breakpoint/releases/tag/v0.2.0")!

    /// The installed app's name: `Breakpoint.app` on macOS, the folder `Breakpoint` on Windows.
    static let appName = BreakpointPlatform.isWindows ? "Breakpoint" : "Breakpoint.app"
    /// Another app beside it.
    static let otherName = BreakpointPlatform.isWindows ? "Other" : "Other.app"

    /// `<folder>/<name>`: the bundle's manifest with these values and an executable
    /// (macOS: `Contents/Info.plist` and `Contents/MacOS/Breakpoint`; Windows:
    /// `breakpoint-app.json` and `Breakpoint.exe`).
    @discardableResult
    func makeApp(in folder: URL, name: String = UpdateFixture.appName, identifier: String = BreakpointVersion.bundleIdentifier,
                 version: String, executable: Bool = true) throws -> URL {
        let app = folder.appendingPathComponent(name, isDirectory: true)
        #if os(Windows)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data(AppBundle.manifest(identifier: identifier, version: version, executable: "Breakpoint.exe").utf8)
            .write(to: app.appendingPathComponent(AppBundle.manifestName))
        if executable {
            try Data("MZ \(version)\n".utf8).write(to: app.appendingPathComponent("Breakpoint.exe"))
            try Data("MZ cli \(version)\n".utf8).write(to: app.appendingPathComponent("bin/breakpoint.exe"))
        }
        #else
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                    "CFBundleExecutable": "Breakpoint"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if executable {
            let binary = macOS.appendingPathComponent("Breakpoint")
            try Data("#!/bin/sh\necho \(version)\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        #endif
        return app
    }

    /// A zipped app, as the release workflow makes it (`ditto` on macOS, `tar -a` on Windows).
    func makeArchive(version: String, identifier: String = BreakpointVersion.bundleIdentifier, extraApp: Bool = false,
                     executable: Bool = true) throws -> URL {
        let source = dir.url.appendingPathComponent("source-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try makeApp(in: source, identifier: identifier, version: version, executable: executable)
        if extraApp { try makeApp(in: source, name: Self.otherName, version: version) }
        let zip = dir.url.appendingPathComponent("Breakpoint-\(version)-\(UUID().uuidString.prefix(6)).zip")
        let process = Process()
        #if os(Windows)
        let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        process.executableURL = URL(fileURLWithPath: root).appendingPathComponent("System32/tar.exe")
        process.arguments = ["-a", "-c", "-f", PathDisplay.native(zip), "-C", PathDisplay.native(source)]
            + (extraApp ? [Self.appName, Self.otherName] : [Self.appName])
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr"] + (extraApp ? [] : ["--keepParent"])
            + [extraApp ? source.path : source.appendingPathComponent("Breakpoint.app").path, zip.path]
        #endif
        try process.run()
        process.waitUntilExit()
        return zip
    }

    /// The feed entry for `archive`, signed as `signedVersion` (default: `version`).
    func release(_ version: String, archive: URL, signedVersion: String? = nil, signer: UpdateSigningKey? = nil) throws -> UpdateRelease {
        let data = try Data(contentsOf: archive)
        return UpdateRelease(version: version, notes: "", page: Self.page,
                             archive: URL(string: "https://github.com/estrindavid/breakpoint/releases/download/v\(version)/x.zip"),
                             size: data.count, sha256: UpdateSignature.sha256Hex(data),
                             signature: try UpdateSignature.sign(version: signedVersion ?? version, archive: data,
                                                                  privateKey: signer ?? key))
    }

    /// `<home>/Applications/Breakpoint.app` at 0.1.0, and an installer for it.
    func installed(current: String = "0.1.0", key: String? = nil) throws -> (URL, UpdateInstaller) {
        let folder = dir.url.appendingPathComponent("Applications", isDirectory: true)
        let app = try makeApp(in: folder, version: current)
        return (app, UpdateInstaller(installedApp: app, current: SemanticVersion(current)!, publicKeyBase64: key ?? publicKey))
    }

    func version(of app: URL) -> String? { UpdateInstaller.bundleInfo(app)?.version }
}

@Suite("Update install: signature, staging, swap and rollback (SPEC §2.11)")
struct UpdateInstallTests {
    // MARK: Signature

    @Test func aGoodArchiveVerifies() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (_, installer) = try f.installed()
        let zip = try f.makeArchive(version: "0.2.0")
        try installer.verify(archive: zip, release: try f.release("0.2.0", archive: zip))
    }

    @Test func theSignedMessageNamesVersionSizeAndHash() {
        let text = String(decoding: UpdateSignature.message(version: "0.2.0", size: 12, sha256: "ABC"), as: UTF8.self)
        #expect(text == "breakpoint-update-v1\nversion 0.2.0\nsize 12\nsha256 abc\n")
    }

    @Test func aTamperedArchiveIsRefused() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (_, installer) = try f.installed()
        let zip = try f.makeArchive(version: "0.2.0")
        let release = try f.release("0.2.0", archive: zip)
        var bytes = try Data(contentsOf: zip)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: zip)
        #expect(throws: UpdateInstallError.checksumMismatch) { try installer.verify(archive: zip, release: release) }
        // A feed that also lies about the hash still fails on the signature.
        var lying = release
        lying.sha256 = UpdateSignature.sha256Hex(bytes)
        #expect(throws: UpdateInstallError.badSignature) { try installer.verify(archive: zip, release: lying) }
        // And a longer file fails on the size.
        try (bytes + Data([0])).write(to: zip)
        #expect(throws: UpdateInstallError.sizeMismatch) { try installer.verify(archive: zip, release: release) }
    }

    @Test func aSignatureFromAnotherKeyIsRefused() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (_, installer) = try f.installed()
        let zip = try f.makeArchive(version: "0.2.0")
        let release = try f.release("0.2.0", archive: zip, signer: UpdateSigningKey())
        #expect(throws: UpdateInstallError.badSignature) { try installer.verify(archive: zip, release: release) }
    }

    @Test func aSignatureCannotBeMovedToAnotherVersion() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (_, installer) = try f.installed()
        let zip = try f.makeArchive(version: "0.2.0")
        // Signed as 0.2.0, offered as 9.0.0.
        let release = try f.release("9.0.0", archive: zip, signedVersion: "0.2.0")
        #expect(throws: UpdateInstallError.badSignature) { try installer.verify(archive: zip, release: release) }
    }

    @Test func anOlderOrSameVersionIsRefusedEvenWhenSigned() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (_, installer) = try f.installed(current: "0.3.0")
        for version in ["0.2.0", "0.3.0"] {
            let zip = try f.makeArchive(version: version)
            #expect(throws: UpdateInstallError.notNewer(version)) {
                try installer.verify(archive: zip, release: try f.release(version, archive: zip))
            }
        }
    }

    @Test func withoutAKeyOrASignatureNothingIsInstalled() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let zip = try f.makeArchive(version: "0.2.0")
        let release = try f.release("0.2.0", archive: zip)
        for key in [nil, "", "not base64", Data(count: 31).base64EncodedString()] as [String?] {
            let installer = UpdateInstaller(installedApp: f.dir.url.appendingPathComponent("B.app"),
                                            current: SemanticVersion("0.1.0")!, publicKeyBase64: key)
            #expect(throws: UpdateInstallError.noKey) { try installer.verify(archive: zip, release: release) }
        }
        let (_, installer) = try f.installed()
        var unsigned = release
        unsigned.signature = nil
        #expect(throws: UpdateInstallError.notInstallable) { try installer.verify(archive: zip, release: unsigned) }
        #expect(UpdateKey.publicKeyBase64 == nil || UpdateSignature.publicKey(UpdateKey.publicKeyBase64) != nil,
                "a committed key must be a valid Ed25519 public key")
    }

    // MARK: Staging

    @Test func stagingUnpacksNextToTheAppAndChecksTheBundle() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (app, installer) = try f.installed()
        let zip = try f.makeArchive(version: "0.2.0")
        let staged = try installer.stage(archive: zip, release: try f.release("0.2.0", archive: zip))
        #expect(staged.stagingDirectory.deletingLastPathComponent() == app.deletingLastPathComponent())
        #expect(staged.stagingDirectory.lastPathComponent.hasPrefix(UpdateInstaller.stagingPrefix))
        #expect(f.version(of: staged.app) == "0.2.0")
        #expect(f.version(of: app) == "0.1.0", "nothing changes before the swap")
    }

    @Test func nothingIsUnpackedBeforeTheSignatureVerifies() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (app, base) = try f.installed()
        var unpacked = false
        var installer = base
        installer.unpack = { _, _ in unpacked = true }
        let zip = try f.makeArchive(version: "0.2.0")
        let forged = try f.release("0.2.0", archive: zip, signer: UpdateSigningKey())
        #expect(throws: UpdateInstallError.badSignature) { try installer.stage(archive: zip, release: forged) }
        #expect(!unpacked)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path)
        #expect(leftovers == [UpdateFixture.appName])
    }

    @Test func aBundleThatIsNotOursIsRefusedAndCleanedUp() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (app, installer) = try f.installed()
        let cases: [(URL, UpdateInstallError)] = [
            (try f.makeArchive(version: "0.2.0", identifier: "com.example.Other"), .wrongBundle("identifier com.example.Other")),
            (try f.makeArchive(version: "0.2.1"), .wrongBundle("version 0.2.1")),
            (try f.makeArchive(version: "0.2.0", executable: false), .wrongBundle("no executable")),
            (try f.makeArchive(version: "0.2.0", extraApp: true), .wrongContents),
        ]
        for (zip, expected) in cases {
            #expect(throws: expected) { try installer.stage(archive: zip, release: try f.release("0.2.0", archive: zip)) }
        }
        let folder = try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path)
        #expect(folder == [UpdateFixture.appName], "every refused staging folder is removed")
    }

    @Test func anArchiveWhoseAppIsALinkIsRefused() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (app, base) = try f.installed()
        // A valid app elsewhere, and an "archive" that unpacks to a link to it.
        let elsewhere = try f.makeApp(in: f.dir.url.appendingPathComponent("elsewhere", isDirectory: true), version: "0.2.0")
        var installer = base
        installer.unpack = { _, folder in
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(UpdateFixture.appName),
                                                       withDestinationURL: elsewhere)
        }
        let zip = try f.makeArchive(version: "0.2.0")
        #expect(throws: UpdateInstallError.wrongContents) {
            try installer.stage(archive: zip, release: try f.release("0.2.0", archive: zip))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path) == [UpdateFixture.appName])
        #expect(f.version(of: elsewhere) == "0.2.0", "the link's target is left alone")
    }

    #if !os(Windows)
    @Test func aQuarantinedDownloadIsRefused() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (_, installer) = try f.installed()
        let zip = try f.makeArchive(version: "0.2.0")
        let release = try f.release("0.2.0", archive: zip)
        let value = "0083;00000000;Safari;"
        #expect(setxattr(zip.path, "com.apple.quarantine", value, value.utf8.count, 0, 0) == 0)
        #expect(throws: UpdateInstallError.quarantined) { try installer.stage(archive: zip, release: release) }
    }
    #endif

    // MARK: Swap and rollback

    @Test func theSwapExchangesTheAppsAndRollbackPutsTheOldOneBack() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (app, installer) = try f.installed()
        let zip = try f.makeArchive(version: "0.2.0")
        let staged = try installer.stage(archive: zip, release: try f.release("0.2.0", archive: zip))
        let swapped = try installer.swap(staged)
        #expect(f.version(of: app) == "0.2.0")
        #expect(f.version(of: swapped.backup) == "0.1.0", "the old app is kept whole until the new one starts")

        try UpdateInstaller.rollback(swapped)
        #expect(f.version(of: app) == "0.1.0")
        #expect(!FileManager.default.fileExists(atPath: swapped.stagingDirectory.path))
    }

    @Test func finishingRemovesTheOldCopy() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (app, installer) = try f.installed()
        let zip = try f.makeArchive(version: "0.2.0")
        let swapped = try installer.swap(try installer.stage(archive: zip, release: try f.release("0.2.0", archive: zip)))
        UpdateInstaller.finish(swapped)
        #expect(try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path) == [UpdateFixture.appName])
        #expect(f.version(of: app) == "0.2.0")
    }

    @Test func aDamagedRecordNeverMovesOrDeletesAnythingElse() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (app, _) = try f.installed()
        // pending-update.json is read back by the relaunch helper; a damaged or hand-edited one
        // must not turn "remove the staging folder" into removing something else.
        let precious = f.dir.url.appendingPathComponent("Documents", isDirectory: true)
        let other = try f.makeApp(in: precious, name: UpdateFixture.otherName, version: "1.0.0")
        let records = [
            SwappedUpdate(installed: app, backup: other, stagingDirectory: precious),
            SwappedUpdate(installed: app, backup: precious.appendingPathComponent(UpdateInstaller.stagingPrefix + "x/B.app"),
                          stagingDirectory: precious.appendingPathComponent(UpdateInstaller.stagingPrefix + "x")),
            SwappedUpdate(installed: precious, backup: other, stagingDirectory: f.dir.url),
        ]
        for record in records {
            UpdateInstaller.finish(record)
            #expect(throws: UpdateInstallError.self) { try UpdateInstaller.rollback(record) }
        }
        #expect(f.version(of: other) == "1.0.0")
        #expect(f.version(of: app) == "0.1.0")
    }

    @Test func leftoversOfAnInterruptedUpdateAreRemoved() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (app, _) = try f.installed()
        let folder = app.deletingLastPathComponent()
        let leftover = folder.appendingPathComponent(UpdateInstaller.stagingPrefix + "abcd1234", isDirectory: true)
        try f.makeApp(in: leftover, version: "0.0.9")
        try f.makeApp(in: folder, name: UpdateFixture.otherName, version: "1.0.0")
        UpdateInstaller.cleanUpLeftovers(nextTo: app)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == [UpdateFixture.appName, UpdateFixture.otherName].sorted())
    }

    // MARK: Where the app lives

    @Test func locations() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (app, _) = try f.installed()
        #expect(UpdateLocation.blocker(for: app) == nil)
        #expect(UpdateLocation.blocker(for: f.dir.url.appendingPathComponent(".build/debug")) == .notAnApp)
        #if os(Windows)
        // NTFS has no permission bits to take away here; the read-only case is macOS's.
        #else
        #expect(UpdateLocation.blocker(for: URL(fileURLWithPath:
            "/private/var/folders/ab/cd/T/AppTranslocation/1234-5678/d/Breakpoint.app")) == .translocated)
        let folder = app.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        guard case .readOnly = UpdateLocation.blocker(for: app) else {
            Issue.record("a folder this user cannot change blocks the install")
            return
        }
        let zip = try f.makeArchive(version: "0.2.0")
        let installer = UpdateInstaller(installedApp: app, current: SemanticVersion("0.1.0")!, publicKeyBase64: f.publicKey)
        #expect(throws: UpdateInstallError.blocked(UpdateLocation.blocker(for: app)!)) {
            try installer.stage(archive: zip, release: try f.release("0.2.0", archive: zip))
        }
        #endif
    }

    // MARK: Relaunch

    /// A relaunch helper whose "launch" and processes are simulated.
    final class FakeWorld {
        var alive: Set<Int32> = []
        var launches: [URL] = []
        var terminated: [Int32] = []
        var onLaunch: ((Int) -> Void)?

        func relauncher(_ file: JSONFile<PendingUpdate>) -> UpdateRelauncher {
            var r = UpdateRelauncher(file: file,
                                     isAlive: { [unowned self] in self.alive.contains($0) },
                                     launch: { [unowned self] url in
                                         self.launches.append(url)
                                         self.onLaunch?(self.launches.count)
                                     },
                                     terminate: { [unowned self] pid in
                                         self.terminated.append(pid)
                                         self.alive.remove(pid)
                                     },
                                     sleep: { _ in },
                                     now: { Fixture.date(12) })
            r.exitTimeout = 1
            r.confirmTimeout = 2
            return r
        }
    }

    func swappedUpdate(_ f: UpdateFixture) throws -> (URL, SwappedUpdate) {
        let (app, installer) = try f.installed()
        let zip = try f.makeArchive(version: "0.2.0")
        return (app, try installer.swap(try installer.stage(archive: zip, release: try f.release("0.2.0", archive: zip))))
    }

    @Test func whenTheNewCopyConfirmsTheOldOneIsRemoved() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (app, swapped) = try swappedUpdate(f)
        let file = PendingUpdate.file(f.dir.paths)
        try file.write(PendingUpdate(fromVersion: "0.1.0", toVersion: "0.2.0", swapped: swapped, startedAt: Fixture.date(12)))
        let world = FakeWorld()
        world.alive = [100]
        world.onLaunch = { _ in
            world.alive.remove(100)
            world.alive.insert(200)
            var pending = try! file.read()!
            pending.newPID = 200
            pending.confirmedAt = Fixture.date(12)
            try! file.write(pending)
        }
        #expect(world.relauncher(file).run(oldPID: 100) == .confirmed)
        #expect(world.launches == [app])
        #expect(f.version(of: app) == "0.2.0")
        #expect(!FileManager.default.fileExists(atPath: swapped.stagingDirectory.path))
        #expect(!file.exists)
    }

    @Test func whenTheNewCopyHangsItIsStoppedAndTheOldOneComesBack() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (app, swapped) = try swappedUpdate(f)
        let file = PendingUpdate.file(f.dir.paths)
        try file.write(PendingUpdate(fromVersion: "0.1.0", toVersion: "0.2.0", swapped: swapped, startedAt: Fixture.date(12)))
        let world = FakeWorld()
        world.onLaunch = { count in
            guard count == 1 else { return }
            world.alive.insert(300) // started, noted its PID, never confirmed
            var pending = try! file.read()!
            pending.newPID = 300
            try! file.write(pending)
        }
        #expect(world.relauncher(file).run(oldPID: 100) == .rolledBack)
        #expect(world.terminated == [300])
        #expect(world.launches == [app, app], "the old copy is started again")
        #expect(f.version(of: app) == "0.1.0")
        #expect(try file.read()?.failedAt == Fixture.date(12), "the old copy reads this and says what happened")
    }

    @Test func whenTheNewCopyCrashesTheOldOneComesBackAtOnce() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let (app, swapped) = try swappedUpdate(f)
        let file = PendingUpdate.file(f.dir.paths)
        try file.write(PendingUpdate(fromVersion: "0.1.0", toVersion: "0.2.0", swapped: swapped, startedAt: Fixture.date(12)))
        let world = FakeWorld()
        var polls = 0
        var relauncher = world.relauncher(file)
        relauncher.confirmTimeout = 1000
        relauncher.sleep = { _ in polls += 1 }
        world.onLaunch = { count in
            guard count == 1 else { return }
            var pending = try! file.read()!
            pending.newPID = 400 // noted, then died
            try! file.write(pending)
        }
        #expect(relauncher.run(oldPID: 100) == .rolledBack)
        #expect(polls < 10, "no need to wait out the timeout")
        #expect(f.version(of: app) == "0.1.0")
    }

    @Test func nothingPendingDoesNothing() throws {
        let f = UpdateFixture()
        defer { f.dir.cleanup() }
        let world = FakeWorld()
        #expect(world.relauncher(PendingUpdate.file(f.dir.paths)).run(oldPID: 1) == .nothingPending)
        #expect(world.launches.isEmpty)
    }

    // MARK: Policy

    @Test func automaticInstallsOnlyWhenAskedForAndQuiet() {
        let release = UpdateRelease(version: "0.2.0", notes: "", page: UpdateFixture.page, archive: UpdateFixture.page, size: 1,
                                    sha256: String(repeating: "a", count: 64), signature: Data(count: 64).base64EncodedString())
        let now = Fixture.date(12)
        let record = UpdatePolicy.checked(.empty, release: release, now: now)
        let quiet = UpdateMoment(secondsSinceKey: 120)
        let current = SemanticVersion("0.1.0")!
        let system = SemanticVersion(major: 15)
        func check(_ r: UpdateRecord = record, automatic: Bool = true, canInstall: Bool = true, moment: UpdateMoment = quiet) -> Bool {
            UpdatePolicy.shouldInstallAutomatically(r, current: current, system: system, automatic: automatic,
                                                    canInstall: canInstall, moment: moment, now: now)
        }
        #expect(check())
        #expect(!check(automatic: false))
        #expect(!check(canInstall: false))
        #expect(!check(moment: UpdateMoment(breakActive: true, secondsSinceKey: 120)))
        #expect(!check(moment: UpdateMoment(callActive: true, secondsSinceKey: 120)))
        #expect(!check(moment: UpdateMoment(secondsSinceKey: 3)))
        #expect(!check(UpdatePolicy.installFailed(record, version: "0.2.0")))
        #expect(!check(UpdatePolicy.postponed(record, version: "0.2.0", now: now)))
        var unsigned = release
        unsigned.signature = nil
        #expect(!check(UpdatePolicy.checked(.empty, release: unsigned, now: now)))
        #expect(!Settings.defaults.installUpdatesAutomatically, "off by default")
    }
}
