import Darwin
import Foundation
import os
import BreakpointCore
import BreakpointRuntime

/// Guarantees a frozen app can never leave displays covered (SPEC §3.3, §7.2, decision 4).
///
/// Contract: while an overlay is up (`start()` … `stop()`), the main thread calls `heartbeat()`
/// every 0.5 s; a dedicated background thread checks it. If the heartbeat is older than 3 s, it
/// appends a line to `logURL`, spawns `/bin/sh -c 'sleep 1; /usr/bin/open -g "<appURL>"'` detached,
/// and calls `_exit(70)`. The background thread must not touch AppKit.
///
/// Implementation notes:
/// - Time is `CLOCK_UPTIME_RAW`, which stops while the Mac sleeps, so a lid close or system sleep
///   during a break never looks like a hang.
/// - The relaunch runs only when `appURL` is an `.app` bundle (a `swift build` binary is not);
///   otherwise the process still exits, which is what removes the windows.
/// - Everything the checking thread needs (the log path, the relaunch command) is prepared as C
///   strings in `start()`, so the exit path allocates nothing and takes no lock but the heartbeat's.
public final class OverlayWatchdog: @unchecked Sendable {
    public let logURL: URL
    public let appURL: URL
    /// Heartbeat age that counts as a hang.
    public let limit: TimeInterval

    private let lastBeat = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private let running = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let generation = OSAllocatedUnfairLock<Int>(initialState: 0)

    public init(logURL: URL, appURL: URL, limit: TimeInterval = BreakTiming.watchdogLimit) {
        self.logURL = logURL
        self.appURL = appURL
        self.limit = limit
    }

    /// True while the checking thread runs.
    public var isRunning: Bool { running.withLock { $0 } }

    public func start() {
        heartbeat()
        let alreadyRunning = running.withLock { value -> Bool in
            defer { value = true }
            return value
        }
        guard !alreadyRunning else { return }
        let myGeneration = generation.withLock { value -> Int in
            value += 1
            return value
        }
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The bundle path is passed as an argument ($0), never spliced into the script, so a path
        // holding `$`, a backtick or a backslash cannot change what the shell runs.
        let relaunch = appURL.pathExtension == "app" ? appURL.path : nil
        let limitNanos = UInt64(limit * 1_000_000_000)
        let logPath = logURL.path
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.check(generation: myGeneration, limitNanos: limitNanos, logPath: logPath, relaunch: relaunch)
        }
        thread.name = "Breakpoint overlay watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    public func heartbeat() {
        let now = Self.uptimeNanos()
        lastBeat.withLock { $0 = now }
    }

    public func stop() {
        running.withLock { $0 = false }
        generation.withLock { $0 += 1 }
    }

    // MARK: Checking thread

    private func check(generation myGeneration: Int, limitNanos: UInt64, logPath: String, relaunch: String?) {
        let interval = useconds_t(BreakTiming.watchdogCheckInterval * 1_000_000)
        while running.withLock({ $0 }) && generation.withLock({ $0 }) == myGeneration {
            usleep(interval)
            guard running.withLock({ $0 }), generation.withLock({ $0 }) == myGeneration else { return }
            let beat = lastBeat.withLock { $0 }
            let now = Self.uptimeNanos()
            if now > beat, now - beat > limitNanos {
                fire(stalledFor: Double(now - beat) / 1_000_000_000, logPath: logPath, relaunch: relaunch)
            }
        }
    }

    /// Logs, relaunches (bundles only) and exits. Never returns.
    private func fire(stalledFor seconds: Double, logPath: String, relaunch: String?) -> Never {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) watchdog: main thread unresponsive for \(String(format: "%.1f", seconds)) s while the break overlay was up; exiting\(relaunch == nil ? "" : " and relaunching")\n"
        let fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            line.withCString { _ = write(fd, $0, strlen($0)) }
            close(fd)
        }
        if let relaunch {
            var pid: pid_t = 0
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
            let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"),
                                                         strdup("sleep 1; exec /usr/bin/open -g \"$0\""), strdup(relaunch), nil]
            _ = posix_spawn(&pid, "/bin/sh", nil, &attributes, argv, environ)
            posix_spawnattr_destroy(&attributes)
        }
        _exit(70)
    }

    private static func uptimeNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}
