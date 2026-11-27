import Foundation
import Testing
@testable import BreakpointCore

@Suite("Update check: versions, the feed, the policy (SPEC §2.11)")
struct UpdateTests {
    // MARK: Version numbers

    @Test func parsesVersionNumbers() {
        #expect(SemanticVersion("0.2.0") == SemanticVersion(major: 0, minor: 2, patch: 0))
        #expect(SemanticVersion("v1.4") == SemanticVersion(major: 1, minor: 4))
        #expect(SemanticVersion("V2") == SemanticVersion(major: 2))
        #expect(SemanticVersion(" 1.2.3 \n") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion("1.0.0-beta.2") == SemanticVersion(major: 1, prerelease: ["beta", "2"]))
        #expect(SemanticVersion("1.0.0+abc123") == SemanticVersion(major: 1))
        #expect(SemanticVersion("1.0.0-rc.1+build.5")?.description == "1.0.0-rc.1")
        for bad in ["", "v", "1.2.3.4", "1..2", "1.x", "a.b.c", "1.2.-3", "1.0.0-", "1.0.0-beta..1", "١.٢.٣", "1.2 .3"] {
            #expect(SemanticVersion(bad) == nil, "\(bad) should not parse")
        }
    }

    @Test func ordersVersionsTheSemanticWay() {
        let ordered = ["0.1.0", "0.1.1", "0.2.0-alpha", "0.2.0-alpha.1", "0.2.0-alpha.beta", "0.2.0-beta",
                       "0.2.0-beta.2", "0.2.0-beta.11", "0.2.0-rc.1", "0.2.0", "0.10.0", "1.0.0", "10.0.0"]
        let versions = ordered.compactMap(SemanticVersion.init)
        #expect(versions.count == ordered.count)
        for i in 0..<versions.count - 1 {
            #expect(versions[i] < versions[i + 1], "\(ordered[i]) < \(ordered[i + 1])")
            #expect(!(versions[i + 1] < versions[i]))
        }
        #expect(SemanticVersion("1.2") == SemanticVersion("1.2.0"))
        #expect(!(SemanticVersion("1.2.0")! < SemanticVersion("v1.2")!))
    }

    @Test func theRunningVersionParses() {
        #expect(SemanticVersion(BreakpointVersion.current) != nil)
        #expect(SemanticVersion.current.description == BreakpointVersion.current)
    }

    // MARK: The feed

    static func feed(_ fields: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: fields)
    }

    static let page = "https://github.com/estrindavid/breakpoint/releases/tag/v0.2.0"
    static let zip = "https://github.com/estrindavid/breakpoint/releases/download/v0.2.0/Breakpoint-0.2.0.zip"

    @Test func readsAFullFeed() throws {
        let release = try UpdateFeed.parse(Self.feed([
            "version": "v0.2.0", "notes": "Breaks now wait for Codex too.\nAnd more below.", "page": Self.page,
            "archive": Self.zip, "size": 4_800_000, "sha256": String(repeating: "AB", count: 32),
            "signature": Data(count: 64).base64EncodedString(), "minimumSystemVersion": "14.0", "published": "2026-11-25T10:00:00Z",
            "somethingNew": [1, 2, 3],
        ]))
        #expect(release.version == "0.2.0")
        #expect(release.notes == "Breaks now wait for Codex too.")
        #expect(release.page.absoluteString == Self.page)
        #expect(release.archive?.absoluteString == Self.zip)
        #expect(release.size == 4_800_000 && release.sha256 == String(repeating: "ab", count: 32))
        #expect(release.isInstallable)
        #expect(release.minimumSystemVersion == "14.0")
        #expect(release.published == ISO8601.date(from: "2026-11-25T10:00:00Z"))
    }

    @Test func aMinimalFeedIsEnough() throws {
        let release = try UpdateFeed.parse(Self.feed(["version": "1.0.0", "page": Self.page]))
        #expect(release.notes.isEmpty && release.archive == nil && release.minimumSystemVersion == nil && release.published == nil)
        #expect(!release.isInstallable, "without an archive and a signature it can only be announced")
        #expect(UpdateCopy.promptDetail(notes: release.notes) == "A new version is on GitHub.")
    }

    @Test func longNotesAreCutToOneShortLine() throws {
        let long = String(repeating: "word ", count: 60)
        let release = try UpdateFeed.parse(Self.feed(["version": "1.0.0", "page": Self.page, "notes": long]))
        #expect(release.notes.count <= UpdateFeed.notesLimit + 1)
        #expect(release.notes.hasSuffix("…"))
    }

    @Test func rejectsFeedsItCannotTrust() {
        #expect(throws: UpdateFeed.ParseError.unreadable) { try UpdateFeed.parse(Data("not json".utf8)) }
        #expect(throws: UpdateFeed.ParseError.unreadable) { try UpdateFeed.parse(Data("[1, 2]".utf8)) }
        #expect(throws: UpdateFeed.ParseError.unreadable) {
            try UpdateFeed.parse(Data(repeating: 32, count: UpdateFeed.maximumSize + 1))
        }
        #expect(throws: UpdateFeed.ParseError.badVersion) { try UpdateFeed.parse(Self.feed(["page": Self.page])) }
        #expect(throws: UpdateFeed.ParseError.badVersion) {
            try UpdateFeed.parse(Self.feed(["version": "latest", "page": Self.page]))
        }
        #expect(throws: UpdateFeed.ParseError.badVersion) {
            try UpdateFeed.parse(Self.feed(["version": 2, "page": Self.page]))
        }
        #expect(throws: UpdateFeed.ParseError.untrustedPage) { try UpdateFeed.parse(Self.feed(["version": "1.0.0"])) }
        let untrusted = [
            "http://github.com/estrindavid/breakpoint/releases",          // not https
            "https://example.com/estrindavid/breakpoint/releases",         // another host
            "https://github.com.example.com/estrindavid/breakpoint",       // a look-alike host
            "https://github.com/someone-else/breakpoint/releases",         // another repository
            "https://github.com/estrindavid/breakpoint-evil/releases",     // a prefix that is not the repository
            "https://github.com/estrindavid/breakpoint/../evil/releases",  // a way out of it
            // … the same, encoded: a browser decodes these dot segments and leaves the repository
            "https://github.com/estrindavid/breakpoint/%2e%2e/%2e%2e/evil/breakpoint/releases",
            "https://github.com/estrindavid/breakpoint/.%2E/.%2E/evil/breakpoint/releases",
            "https://github.com/estrindavid/breakpoint%2f..%2f..%2fevil",
            "https://github.com/estrindavid/breakpoint/releases/%2e%2e/%2e%2e/%2e%2e/evil",
            "https://github.com/estrindavid/breakpoint/releases/./tag",       // any dot segment
            "https://github.com/estrindavid/breakpoint/..%5c..%5cevil",       // an encoded backslash
            "https://user@github.com/estrindavid/breakpoint/releases",     // credentials
            "https://github.com:8443/estrindavid/breakpoint/releases",     // a port
            "file:///Applications/Breakpoint.app",
            "javascript:alert(1)",
        ]
        for page in untrusted {
            #expect(throws: UpdateFeed.ParseError.untrustedPage, "\(page)") {
                try UpdateFeed.parse(Self.feed(["version": "1.0.0", "page": page]))
            }
        }
    }

    @Test func dropsAnUntrustedDownloadButKeepsTheRelease() throws {
        let release = try UpdateFeed.parse(Self.feed(["version": "1.0.0", "page": Self.page,
                                                      "archive": "https://example.com/Breakpoint.zip", "size": 10,
                                                      "sha256": "xyz", "signature": "c2hvcnQ="]))
        #expect(release.archive == nil && release.sha256 == nil && release.signature == nil)
        #expect(!release.isInstallable)
    }

    @Test func theFeedAddressIsInsideTheRepository() {
        #expect(UpdateFeed.isTrusted(UpdateFeed.url))
        // One feed per platform: installed Macs keep reading update-feed.json.
        #expect(UpdateFeed.url.absoluteString
                == "https://github.com/estrindavid/breakpoint/releases/latest/download/"
                + (BreakpointPlatform.isWindows ? "update-feed-windows.json" : "update-feed.json"))
    }

    @Test func minimumSystemVersion() {
        var release = UpdateRelease(version: "1.0.0", notes: "", page: URL(string: Self.page)!, minimumSystemVersion: "15.0")
        #expect(!release.runs(on: SemanticVersion(major: 14, minor: 6)))
        #expect(release.runs(on: SemanticVersion(major: 15)))
        #expect(release.runs(on: SemanticVersion(major: 26, minor: 1)))
        release.minimumSystemVersion = nil
        #expect(release.runs(on: SemanticVersion(major: 14)))
    }

    // MARK: The policy

    static let start = Fixture.date(10)
    static let quiet = UpdateMoment(secondsSinceKey: 120)
    static let current = SemanticVersion(major: 0, minor: 1)
    static let system = SemanticVersion(major: 15)

    static func release(_ version: String, minimum: String? = nil) -> UpdateRelease {
        UpdateRelease(version: version, notes: "Something new.", page: URL(string: page)!, minimumSystemVersion: minimum)
    }

    @Test func checksOncePerDayAfterTheFirstMinutes() {
        let launch = Self.start
        var record = UpdateRecord.empty
        #expect(!UpdatePolicy.checkIsDue(record, automatic: true, launchedAt: launch, now: launch))
        #expect(!UpdatePolicy.checkIsDue(record, automatic: true, launchedAt: launch,
                                         now: launch.addingTimeInterval(Timing.updateFirstCheckDelay - 1)))
        let first = launch.addingTimeInterval(Timing.updateFirstCheckDelay)
        #expect(UpdatePolicy.checkIsDue(record, automatic: true, launchedAt: launch, now: first))
        #expect(!UpdatePolicy.checkIsDue(record, automatic: false, launchedAt: launch, now: first))

        record = UpdatePolicy.checked(record, release: Self.release("0.1.0"), now: first)
        #expect(!UpdatePolicy.checkIsDue(record, automatic: true, launchedAt: launch,
                                         now: first.addingTimeInterval(Timing.updateCheckInterval - 1)))
        #expect(UpdatePolicy.checkIsDue(record, automatic: true, launchedAt: launch,
                                        now: first.addingTimeInterval(Timing.updateCheckInterval)))
    }

    @Test func aRelaunchDoesNotCheckEarly() {
        let checkedAt = Self.start
        let record = UpdatePolicy.checked(.empty, release: Self.release("0.1.0"), now: checkedAt)
        let relaunch = checkedAt.addingTimeInterval(3600)
        #expect(!UpdatePolicy.checkIsDue(record, automatic: true, launchedAt: relaunch,
                                         now: relaunch.addingTimeInterval(Timing.updateFirstCheckDelay)))
    }

    @Test func aFailedCheckTriesAgainSooner() {
        let launch = Self.start
        let failedAt = launch.addingTimeInterval(Timing.updateFirstCheckDelay)
        var record = UpdatePolicy.failed(.empty, now: failedAt)
        #expect(record.lastAttemptFailed && record.lastCheckedAt == nil)
        #expect(!UpdatePolicy.checkIsDue(record, automatic: true, launchedAt: launch,
                                         now: failedAt.addingTimeInterval(Timing.updateRetryAfterFailure - 1)))
        #expect(UpdatePolicy.checkIsDue(record, automatic: true, launchedAt: launch,
                                        now: failedAt.addingTimeInterval(Timing.updateRetryAfterFailure)))
        // A failure keeps what an earlier check learned.
        record = UpdatePolicy.checked(.empty, release: Self.release("0.3.0"), now: launch)
        record = UpdatePolicy.failed(record, now: failedAt)
        #expect(record.latest?.version == "0.3.0" && record.lastCheckedAt == launch)
    }

    @Test func aClockSetBackStillChecks() {
        let record = UpdatePolicy.checked(.empty, release: Self.release("0.1.0"), now: Self.start.addingTimeInterval(86_400 * 30))
        #expect(UpdatePolicy.checkIsDue(record, automatic: true, launchedAt: Self.start.addingTimeInterval(-3600),
                                        now: Self.start))
    }

    @Test func checksOnlyAtQuietMoments() {
        #expect(UpdatePolicy.mayCheck(Self.quiet))
        #expect(UpdatePolicy.mayCheck(UpdateMoment(away: true, secondsSinceKey: 0)), "a check is invisible: away or typing is fine")
        let busy: [UpdateMoment] = [
            UpdateMoment(onboarded: false), UpdateMoment(breakActive: true), UpdateMoment(nudgeVisible: true),
            UpdateMoment(cardsVisible: true), UpdateMoment(paused: true), UpdateMoment(callActive: true),
        ]
        for moment in busy {
            #expect(!UpdatePolicy.mayCheck(moment), "\(moment)")
            #expect(!UpdatePolicy.mayPrompt(moment), "\(moment)")
        }
        #expect(!UpdatePolicy.mayPrompt(UpdateMoment(away: true, secondsSinceKey: 600)))
        #expect(!UpdatePolicy.mayPrompt(UpdateMoment(secondsSinceKey: Timing.updatePromptQuiet - 1)))
        #expect(UpdatePolicy.mayPrompt(UpdateMoment(secondsSinceKey: Timing.updatePromptQuiet)))
    }

    @Test func offersOnlyNewerVersionsThatRunHere() {
        func record(_ release: UpdateRelease) -> UpdateRecord { UpdatePolicy.checked(.empty, release: release, now: Self.start) }
        #expect(UpdatePolicy.available(.empty, current: Self.current, system: Self.system) == nil)
        #expect(UpdatePolicy.available(record(Self.release("0.1.0")), current: Self.current, system: Self.system) == nil)
        #expect(UpdatePolicy.available(record(Self.release("0.0.9")), current: Self.current, system: Self.system) == nil)
        #expect(UpdatePolicy.available(record(Self.release("0.1.1")), current: Self.current, system: Self.system)?.version == "0.1.1")
        #expect(UpdatePolicy.available(record(Self.release("0.2.0", minimum: "26.0")), current: Self.current,
                                       system: Self.system) == nil)
        #expect(UpdatePolicy.available(record(Self.release("0.2.0", minimum: "15.0")), current: Self.current,
                                       system: Self.system) != nil)
    }

    @Test func laterPutsTheQuestionOffForThreeDays() {
        var record = UpdatePolicy.checked(.empty, release: Self.release("0.2.0"), now: Self.start)
        let asked = Self.start.addingTimeInterval(60)
        #expect(UpdatePolicy.shouldPrompt(record, current: Self.current, system: Self.system, moment: Self.quiet, now: asked))
        #expect(!UpdatePolicy.shouldPrompt(record, current: Self.current, system: Self.system,
                                           moment: UpdateMoment(cardsVisible: true, secondsSinceKey: 120), now: asked))

        record = UpdatePolicy.postponed(record, version: "0.2.0", now: asked)
        #expect(!UpdatePolicy.shouldPrompt(record, current: Self.current, system: Self.system, moment: Self.quiet,
                                           now: asked.addingTimeInterval(Timing.updatePostpone - 1)))
        #expect(UpdatePolicy.shouldPrompt(record, current: Self.current, system: Self.system, moment: Self.quiet,
                                          now: asked.addingTimeInterval(Timing.updatePostpone)))

        // A newer version than the one put off is news: it is offered at once.
        record = UpdatePolicy.checked(record, release: Self.release("0.3.0"), now: asked.addingTimeInterval(3600))
        #expect(UpdatePolicy.shouldPrompt(record, current: Self.current, system: Self.system, moment: Self.quiet,
                                          now: asked.addingTimeInterval(3600)))
    }

    @Test func theTimingConstants() {
        #expect(Timing.updateCheckInterval == 24 * 3600)
        #expect(Timing.updatePostpone == 3 * 24 * 3600)
        #expect(Timing.updateRetryAfterFailure < Timing.updateCheckInterval)
        #expect(Timing.updateFirstCheckDelay >= 60)
    }

    // MARK: Storage and copy

    @Test func theRecordSurvivesARelaunchAndToleratesDamage() throws {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        #expect(UpdateRecord.load(dir.paths) == .empty)
        var record = UpdatePolicy.checked(.empty, release: Self.release("0.2.0"), now: Self.start)
        record = UpdatePolicy.postponed(record, version: "0.2.0", now: Self.start)
        try UpdateRecord.file(dir.paths).write(record)
        #expect(UpdateRecord.load(dir.paths) == record)
        #expect(dir.paths.updatesFile.lastPathComponent == "updates.json")

        try Data("{\"lastAttemptAt\": \"yesterday\", \"latest\": 7, \"postponedVersion\": \"0.2.0\"}".utf8)
            .write(to: dir.paths.updatesFile)
        let damaged = UpdateRecord.load(dir.paths)
        #expect(damaged.lastAttemptAt == nil && damaged.latest == nil && damaged.postponedVersion == "0.2.0")
        try Data("not json".utf8).write(to: dir.paths.updatesFile)
        #expect(UpdateRecord.load(dir.paths) == .empty)
    }

    @Test func theSettingIsOnByDefaultAndSurvivesOldFiles() throws {
        #expect(Settings.defaults.checkForUpdates)
        let old = try JSONFile<Settings>.decoder.decode(Settings.self, from: Data("{\"version\": 1}".utf8))
        #expect(old.checkForUpdates)
        let off = try JSONFile<Settings>.decoder.decode(Settings.self, from: Data("{\"checkForUpdates\": false}".utf8))
        #expect(!off.checkForUpdates)
        var s = Settings()
        s.checkForUpdates = false
        #expect(try Fixture.jsonRoundTrip(s).checkForUpdates == false)
    }

    @Test func copy() {
        #expect(UpdateCopy.promptTitle(version: "0.2.0") == "Breakpoint 0.2.0 is ready")
        #expect(UpdateCopy.available(version: "0.2.0") == "Version 0.2.0 is available")
        let now = Fixture.date(15)
        let utc = Fixture.utc
        let locale = Locale(identifier: "en_GB")
        #expect(UpdateCopy.lastChecked(Fixture.date(9, 12), now: now, calendar: Fixture.calendar, locale: locale, timeZone: utc)
                == "Checked today at 09:12")
        #expect(UpdateCopy.lastChecked(Fixture.date(18, 40, day: 21), now: now, calendar: Fixture.calendar, locale: locale,
                                       timeZone: utc) == "Checked yesterday at 18:40")
        #expect(UpdateCopy.lastChecked(Fixture.date(8, day: 3), now: now, calendar: Fixture.calendar, locale: locale,
                                       timeZone: utc) == "Checked on 3 Nov")
        for line in [UpdateCopy.checking, UpdateCopy.upToDate, UpdateCopy.neverChecked, UpdateCopy.failed,
                     UpdateCopy.automaticDescription, UpdateCopy.promptTitle(version: "1.0.0"),
                     UpdateCopy.promptDetail(notes: "")] {
            #expect(!line.contains("!") && !line.lowercased().contains("should"), "\(line)")
        }
    }
}
