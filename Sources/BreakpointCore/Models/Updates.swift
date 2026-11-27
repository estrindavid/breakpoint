import Foundation

// The update check (SPEC §2.11): version numbers, the release feed, and what the app remembers
// between checks. Pure values; the fetch lives in BreakpointKit (`UpdateFetcher`), the signature
// check and the install in Updates/.

// MARK: - Version numbers

/// A version number such as `0.2.0`, `v1.4` or `1.0.0-beta.2`, compared the way Semantic
/// Versioning orders them: numerically part by part (missing parts count as 0), and a pre-release
/// (`-beta.2`) before the release it leads to. Build metadata (`+abc`) is ignored.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Dot-separated pre-release identifiers (`["beta", "2"]`); empty for a release.
    public var prerelease: [String]

    public init(major: Int, minor: Int = 0, patch: Int = 0, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Parses `1`, `1.2`, `1.2.3`, an optional leading `v`, an optional `-pre.release` and an
    /// optional `+build`. `nil` for anything else (letters in the numbers, four parts, empty).
    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        if let plus = rest.firstIndex(of: "+") { rest = rest[..<plus] }
        var prerelease: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            let tail = rest[rest.index(after: dash)...]
            prerelease = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let valid = prerelease.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
            guard valid else { return nil }
            rest = rest[..<dash]
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: prerelease)
    }

    /// `1.2.3` or `1.2.3-beta.2`.
    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // A release ranks above any of its pre-releases.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (.some, nil): return true   // numeric identifiers rank below alphanumeric ones
            case (nil, .some): return false
            case (nil, nil): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    /// The running app's version (`BreakpointVersion.current`).
    public static var current: SemanticVersion {
        SemanticVersion(BreakpointVersion.current) ?? SemanticVersion(major: 0)
    }

    /// The macOS version this process runs on.
    public static var operatingSystem: SemanticVersion {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return SemanticVersion(major: v.majorVersion, minor: v.minorVersion, patch: v.patchVersion)
    }
}

// MARK: - The release feed

/// One published release, as the feed describes it.
public struct UpdateRelease: Codable, Equatable, Hashable, Sendable {
    /// `0.2.0` (no leading `v`).
    public var version: String
    /// What's new, in one line (at most `UpdateFeed.notesLimit` characters).
    public var notes: String
    /// The release page on GitHub: what "Open download page" opens.
    public var page: URL
    /// The zipped app on GitHub (`Breakpoint-0.2.0.zip`), what Update downloads.
    public var archive: URL?
    /// The archive's size in bytes, as signed.
    public var size: Int?
    /// The archive's SHA-256, lowercase hex, as signed.
    public var sha256: String?
    /// Base64 Ed25519 signature of `UpdateSignature.message(version:size:sha256:)`, made with the
    /// release key; `nil` when the release was published without the key (then Update is not offered).
    public var signature: String?
    /// The oldest macOS the release runs on (`14.0`).
    public var minimumSystemVersion: String?
    public var published: Date?

    public init(version: String, notes: String, page: URL, archive: URL? = nil, size: Int? = nil, sha256: String? = nil,
                signature: String? = nil, minimumSystemVersion: String? = nil, published: Date? = nil) {
        self.version = version
        self.notes = notes
        self.page = page
        self.archive = archive
        self.size = size
        self.sha256 = sha256
        self.signature = signature
        self.minimumSystemVersion = minimumSystemVersion
        self.published = published
    }

    public var semanticVersion: SemanticVersion? { SemanticVersion(version) }

    /// The feed carries everything an in-place install needs (it may still be refused on checking).
    public var isInstallable: Bool { archive != nil && size != nil && sha256 != nil && signature != nil }

    /// Whether this release runs on `system` (always, when the feed names no minimum).
    public func runs(on system: SemanticVersion) -> Bool {
        guard let minimum = minimumSystemVersion.flatMap(SemanticVersion.init) else { return true }
        return system >= minimum
    }
}

/// Where the feed lives and how to read it. The feed is a small JSON file attached to every GitHub
/// release by the release workflow (`scripts/make-update-feed.sh`); GitHub redirects
/// `releases/latest/download/<name>` to the newest non-draft, non-pre-release copy of it.
public enum UpdateFeed {
    /// The repository every release comes from. Download only ever opens pages inside it.
    public static let repository = URL(string: "https://github.com/estrindavid/breakpoint")!
    /// The feed's file name on each release: one per platform, so each app reads only releases of
    /// its own archive (installed Macs keep reading `update-feed.json`, as before).
    #if os(Windows)
    public static let assetName = "update-feed-windows.json"
    #else
    public static let assetName = "update-feed.json"
    #endif
    /// The one address the app ever connects to.
    public static let url = URL(string: "\(repository.absoluteString)/releases/latest/download/\(assetName)")!
    /// Longer notes are cut to this many characters (plus "…").
    public static let notesLimit = 120
    /// A feed larger than this is not read.
    public static let maximumSize = 64 * 1024
    /// An archive larger than this is not downloaded.
    public static let maximumArchiveSize = 64 * 1024 * 1024

    public enum ParseError: Error, Equatable, Sendable {
        /// Not a JSON object, or too large.
        case unreadable
        /// `version` is missing or not a version number.
        case badVersion
        /// `page` is missing, or points outside `repository` (or is not https).
        case untrustedPage
    }

    /// Reads a feed. Tolerant of extra keys and missing optional ones; strict about the version and
    /// about where Download may lead (only https pages inside `repository`), so a tampered or
    /// mistaken feed can never send someone elsewhere.
    public static func parse(_ data: Data) throws -> UpdateRelease {
        guard data.count <= maximumSize,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ParseError.unreadable
        }
        guard let rawVersion = object["version"] as? String, let version = SemanticVersion(rawVersion) else {
            throw ParseError.badVersion
        }
        guard let page = (object["page"] as? String).flatMap(URL.init(string:)), isTrusted(page) else {
            throw ParseError.untrustedPage
        }
        let archive = (object["archive"] as? String).flatMap(URL.init(string:)).flatMap { isTrusted($0) ? $0 : nil }
        let size = (object["size"] as? Int).flatMap { (1...maximumArchiveSize).contains($0) ? $0 : nil }
        let sha256 = (object["sha256"] as? String).map { $0.lowercased() }.flatMap { hex in
            hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
        }
        let signature = (object["signature"] as? String).flatMap { Data(base64Encoded: $0)?.count == 64 ? $0 : nil }
        let notes = TextFormat.truncated(TextFormat.firstLine(object["notes"] as? String ?? ""), limit: notesLimit)
        let minimum = (object["minimumSystemVersion"] as? String).flatMap { SemanticVersion($0) != nil ? $0 : nil }
        let published = (object["published"] as? String).flatMap(ISO8601.date(from:))
        return UpdateRelease(version: version.description, notes: notes, page: page, archive: archive, size: size,
                             sha256: sha256, signature: signature, minimumSystemVersion: minimum, published: published)
    }

    /// https, host github.com, and a path inside the repository. The path may hold no
    /// percent-escapes and no `.` or `..` segments: a browser decodes `%2e%2e` to `..`, so
    /// `…/breakpoint/%2e%2e/%2e%2e/other` would open a page outside the repository.
    public static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == repository.host, url.user == nil, url.port == nil,
              let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              !encodedPath.contains("%"), !encodedPath.contains("\\"),
              !encodedPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            return false
        }
        let path = url.standardized.path
        let base = repository.path
        return path == base || path.hasPrefix(base + "/")
    }
}

// MARK: - What the app remembers

/// The state of the update check, kept in `updates.json` (SPEC §8) so a relaunch neither checks
/// again early nor asks again about a version the person put off.
public struct UpdateRecord: Codable, Equatable, Sendable {
    /// The last check, whatever its result.
    public var lastAttemptAt: Date?
    /// The last check that reached the feed.
    public var lastCheckedAt: Date?
    /// The last attempt failed (the next one comes sooner, `Timing.updateRetryAfterFailure`).
    public var lastAttemptFailed: Bool
    /// The newest release the feed named, as of `lastCheckedAt`.
    public var latest: UpdateRelease?
    /// "Later" (or a prompt that went unanswered) for this version …
    public var postponedVersion: String?
    /// … until this time.
    public var postponedUntil: Date?
    /// An install of this version failed (or was rolled back): it is not tried automatically again,
    /// and About offers the download page.
    public var installFailedVersion: String?

    public init(lastAttemptAt: Date? = nil, lastCheckedAt: Date? = nil, lastAttemptFailed: Bool = false,
                latest: UpdateRelease? = nil, postponedVersion: String? = nil, postponedUntil: Date? = nil,
                installFailedVersion: String? = nil) {
        self.lastAttemptAt = lastAttemptAt
        self.lastCheckedAt = lastCheckedAt
        self.lastAttemptFailed = lastAttemptFailed
        self.latest = latest
        self.postponedVersion = postponedVersion
        self.postponedUntil = postponedUntil
        self.installFailedVersion = installFailedVersion
    }

    public static let empty = UpdateRecord()

    public static func file(_ paths: BreakpointPaths) -> JSONFile<UpdateRecord> { JSONFile(url: paths.updatesFile) }

    /// The record on disk, or an empty one if it is missing or unreadable.
    public static func load(_ paths: BreakpointPaths) -> UpdateRecord {
        ((try? file(paths).read()) ?? nil) ?? .empty
    }

    enum CodingKeys: String, CodingKey {
        case lastAttemptAt, lastCheckedAt, lastAttemptFailed, latest, postponedVersion, postponedUntil, installFailedVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastAttemptAt = try? c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastCheckedAt = try? c.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        lastAttemptFailed = (try? c.decodeIfPresent(Bool.self, forKey: .lastAttemptFailed)) ?? false
        latest = try? c.decodeIfPresent(UpdateRelease.self, forKey: .latest)
        postponedVersion = try? c.decodeIfPresent(String.self, forKey: .postponedVersion)
        postponedUntil = try? c.decodeIfPresent(Date.self, forKey: .postponedUntil)
        installFailedVersion = try? c.decodeIfPresent(String.self, forKey: .installFailedVersion)
    }
}
