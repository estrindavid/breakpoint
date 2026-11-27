import Foundation

/// An in-place update in flight, in `pending-update.json` (SPEC §2.11, §8). The old copy writes it
/// before it quits; the new copy notes its process ID and confirms it started; the relaunch helper
/// cleans up, or puts the old copy back.
public struct PendingUpdate: Codable, Equatable, Sendable {
    public var fromVersion: String
    public var toVersion: String
    public var swapped: SwappedUpdate
    public var startedAt: Date
    /// The new copy's process, as soon as it runs.
    public var newPID: Int32?
    public var confirmedAt: Date?
    /// The new copy did not confirm in time: the old one is back.
    public var failedAt: Date?

    public init(fromVersion: String, toVersion: String, swapped: SwappedUpdate, startedAt: Date,
                newPID: Int32? = nil, confirmedAt: Date? = nil, failedAt: Date? = nil) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.swapped = swapped
        self.startedAt = startedAt
        self.newPID = newPID
        self.confirmedAt = confirmedAt
        self.failedAt = failedAt
    }

    public static func file(_ paths: BreakpointPaths) -> JSONFile<PendingUpdate> { JSONFile(url: paths.pendingUpdateFile) }
}

/// What `breakpoint update-relaunch` does, run from the old copy's bundle (now the backup) after
/// the old copy quit: start the new copy, wait for it to confirm, then remove the old one; if it
/// does not confirm (it crashed, hung, or another copy answered), stop it, swap the old copy back
/// and start that instead. Every effect is injectable so the sequence is tested without launching
/// anything.
public struct UpdateRelauncher {
    public enum Outcome: Equatable, Sendable {
        case nothingPending
        case confirmed
        case rolledBack
        case rollbackFailed(String)
    }

    public var file: JSONFile<PendingUpdate>
    public var isAlive: (Int32) -> Bool
    /// Starts the app at a URL (`AppBundle.open`).
    public var launch: (URL) throws -> Void
    public var terminate: (Int32) -> Void
    public var sleep: (TimeInterval) -> Void
    public var now: () -> Date
    public var exitTimeout: TimeInterval = Timing.updateOldCopyExitTimeout
    public var confirmTimeout: TimeInterval = Timing.updateConfirmTimeout
    public var pollInterval: TimeInterval = 0.25

    public init(file: JSONFile<PendingUpdate>,
                isAlive: @escaping (Int32) -> Bool = AppBundle.isAlive,
                launch: @escaping (URL) throws -> Void = UpdateRelauncher.open,
                terminate: @escaping (Int32) -> Void = UpdateRelauncher.stop,
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                now: @escaping () -> Date = Date.init) {
        self.file = file
        self.isAlive = isAlive
        self.launch = launch
        self.terminate = terminate
        self.sleep = sleep
        self.now = now
    }

    public func run(oldPID: Int32) -> Outcome {
        guard var pending = (try? file.read()) ?? nil, pending.confirmedAt == nil, pending.failedAt == nil else {
            return .nothingPending
        }
        // 1. The old copy quits (it still holds the socket until it does).
        var waited: TimeInterval = 0
        while isAlive(oldPID), waited < exitTimeout {
            sleep(pollInterval)
            waited += pollInterval
        }
        // 2. Start the new copy and wait for it to say it started.
        var started = (try? launch(pending.swapped.installed)) != nil
        waited = 0
        while started, waited < confirmTimeout {
            sleep(pollInterval)
            waited += pollInterval
            guard let current = (try? file.read()) ?? nil else { break }
            pending = current
            if pending.confirmedAt != nil {
                UpdateInstaller.finish(pending.swapped)
                try? FileManager.default.removeItem(at: file.url)
                return .confirmed
            }
            // It started and died: no need to wait out the timeout.
            if let pid = pending.newPID, !isAlive(pid) { started = false }
        }
        // 3. Put the old copy back and start it; it tells the person what happened.
        if let pid = pending.newPID, isAlive(pid) { terminate(pid) }
        do {
            try UpdateInstaller.rollback(pending.swapped)
        } catch {
            return .rollbackFailed("\(error)")
        }
        pending.failedAt = now()
        try? file.write(pending)
        try? launch(pending.swapped.installed)
        return .rolledBack
    }

    public static func open(_ app: URL) throws { try AppBundle.open(app) }

    /// Ends the process: a polite request first, then for good two seconds later.
    public static func stop(_ pid: Int32) { AppBundle.stop(pid) }
}
