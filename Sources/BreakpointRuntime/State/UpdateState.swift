import Foundation
import BreakpointCore

/// The steps of an in-place update, as the card and About show them.
public enum UpdateInstallStep: String, Equatable, Sendable {
    case downloading, verifying, installing, reopening

    public var text: String {
        switch self {
        case .downloading: return UpdateCopy.downloading
        case .verifying: return UpdateCopy.verifying
        case .installing: return UpdateCopy.installing
        case .reopening: return UpdateCopy.reopening
        }
    }
}

/// What Settings → About shows about updates (SPEC §2.11, §3.9).
public enum UpdatePhase: Equatable, Sendable {
    /// Never checked.
    case idle
    /// A check is on its way.
    case checking
    /// The last check found nothing newer.
    case upToDate
    /// A newer release that runs on this Mac.
    case available(UpdateRelease)
    /// Downloading, checking, installing or reopening.
    case installing(UpdateRelease, UpdateInstallStep)
    /// Installing this release failed: one sentence why; the download page still works.
    case installFailed(UpdateRelease, String)
    /// The last check could not reach the feed (or could not read it).
    case failed
}

public struct UpdateState: Equatable, Sendable {
    /// `BreakpointVersion.current`.
    public var currentVersion: String
    public var phase: UpdatePhase
    /// The last check that reached the feed.
    public var lastCheckedAt: Date?
    /// Why this copy cannot install updates itself (no release key yet, a development build, a
    /// read-only folder, a translocated copy); `nil` when Update installs in place.
    public var installBlocker: String?

    public init(currentVersion: String = BreakpointVersion.current, phase: UpdatePhase = .idle, lastCheckedAt: Date? = nil,
                installBlocker: String? = nil) {
        self.currentVersion = currentVersion
        self.phase = phase
        self.lastCheckedAt = lastCheckedAt
        self.installBlocker = installBlocker
    }

    /// The newer release, whatever is happening to it.
    public var release: UpdateRelease? {
        switch phase {
        case .available(let release), .installing(let release, _), .installFailed(let release, _): return release
        default: return nil
        }
    }

    /// Update installs in place (otherwise the button opens the download page). Not for a release
    /// whose install already failed: its download page is the way.
    public var canInstall: Bool {
        guard installBlocker == nil, let release else { return false }
        if case .installFailed = phase { return false }
        return release.isInstallable
    }
}

/// The update prompt: a newer release, in one line, and what is happening to it.
public struct UpdateCardContent: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        /// Later / Update (or Download page when this copy cannot install).
        case offer
        case installing(UpdateInstallStep)
        /// Close / Open download page.
        case failed(String)
    }

    public var release: UpdateRelease
    public var canInstall: Bool
    public var stage: Stage

    public init(release: UpdateRelease, canInstall: Bool = true, stage: Stage = .offer) {
        self.release = release
        self.canInstall = canInstall
        self.stage = stage
    }

    public var title: String {
        if case .failed = stage { return UpdateCopy.installFailedTitle(version: release.version) }
        return UpdateCopy.promptTitle(version: release.version)
    }

    public var detail: String {
        switch stage {
        case .offer: return UpdateCopy.promptDetail(notes: release.notes)
        case .installing(let step): return step.text
        case .failed(let reason): return reason
        }
    }
}
