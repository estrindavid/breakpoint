import BreakpointCore
import Foundation
import WinSDK

/// Guarantees a frozen app can never leave the displays covered (SPEC §3.3, §7.2), as the Mac's
/// `OverlayWatchdog`: while an overlay is up (`start()` … `stop()`) the main thread calls
/// `heartbeat()` every 0.5 s and a background thread checks it. A heartbeat older than 3 s means
/// the main thread is stuck: the thread appends a line to `logURL` (when set), starts
/// `relaunchExecutable` (when set, detached, after a second) and ends the process, which removes
/// every overlay window.
///
/// Time is `QueryUnbiasedInterruptTime`, which stops while the PC sleeps, so sleep during a break
/// never looks like a hang. Everything the checking thread needs is prepared in `start()`; it
/// never touches the UI.
public final class OverlayWatchdog: @unchecked Sendable {
    /// Where the line goes (the shell sets it to the app's log).
    public var logURL: URL?
    /// The app to start again after the exit (an installed copy; nil for development builds).
    public var relaunchExecutable: URL?
    /// Heartbeat age that counts as a hang.
    public var limit: TimeInterval = OverlayMetrics.watchdogLimit

    private let lock = NSLock()
    private var lastBeat: UInt64 = 0
    private var running = false
    private var generation = 0

    public init() {}

    public var isRunning: Bool { lock.withLock { running } }

    public func start() {
        heartbeat()
        let (alreadyRunning, myGeneration): (Bool, Int) = lock.withLock {
            let was = running
            running = true
            if !was { generation += 1 }
            return (was, generation)
        }
        guard !alreadyRunning else { return }
        let limitTicks = UInt64(limit * 10_000_000)
        let logPath = logURL.map { PathDisplay.native($0) }
        let command = relaunchExecutable.map { "cmd.exe /c ping -n 2 127.0.0.1 >nul & start \"\" \"\(PathDisplay.native($0))\"" }
        let thread = Thread { [weak self] in
            self?.check(generation: myGeneration, limitTicks: limitTicks, logPath: logPath, relaunch: command)
        }
        thread.name = "Breakpoint overlay watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    public func heartbeat() {
        let now = Self.ticks()
        lock.withLock { lastBeat = now }
    }

    public func stop() {
        lock.withLock {
            running = false
            generation += 1
        }
    }

    // MARK: Checking thread

    private func check(generation myGeneration: Int, limitTicks: UInt64, logPath: String?, relaunch: String?) {
        let interval = OverlayMetrics.watchdogCheckInterval
        while true {
            Thread.sleep(forTimeInterval: interval)
            let (live, beat): (Bool, UInt64) = lock.withLock { (running && generation == myGeneration, lastBeat) }
            guard live else { return }
            let now = Self.ticks()
            if now > beat, now - beat > limitTicks {
                fire(stalledFor: Double(now - beat) / 10_000_000, logPath: logPath, relaunch: relaunch)
            }
        }
    }

    private func fire(stalledFor seconds: Double, logPath: String?, relaunch: String?) -> Never {
        if let logPath {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(stamp) watchdog: main thread unresponsive for \(String(format: "%.1f", seconds)) s while the break overlay was up; exiting\(relaunch == nil ? "" : " and relaunching")\n"
            if let handle = FileHandle(forWritingAtPath: logPath) ?? {
                _ = FileManager.default.createFile(atPath: logPath, contents: nil)
                return FileHandle(forWritingAtPath: logPath)
            }() {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        }
        if let relaunch {
            var startup = STARTUPINFOW()
            startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
            startup.dwFlags = DWORD(STARTF_USESHOWWINDOW)
            startup.wShowWindow = WORD(SW_HIDE)
            var info = PROCESS_INFORMATION()
            var commandLine = Array(relaunch.utf16) + [0]
            if CreateProcessW(nil, &commandLine, nil, nil, false, DWORD(DETACHED_PROCESS | CREATE_NO_WINDOW), nil, nil,
                              &startup, &info) {
                CloseHandle(info.hProcess)
                CloseHandle(info.hThread)
            }
        }
        TerminateProcess(GetCurrentProcess(), 70)
        fatalError("watchdog exit")
    }

    /// 100 ns units that stop while the PC sleeps.
    private static func ticks() -> UInt64 {
        var value: ULONGLONG = 0
        QueryUnbiasedInterruptTime(&value)
        return UInt64(value)
    }
}
