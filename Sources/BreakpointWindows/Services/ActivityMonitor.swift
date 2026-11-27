import BreakpointCore
import BreakpointRuntime
import CBreakpointWin32
import Foundation
import WinSDK

/// The input, call and presence signals of SPEC §2.4 on Windows, read without any hook, raw
/// input registration or permission (no keyboard or mouse event ever reaches Breakpoint):
///
/// - Input recency: `GetLastInputInfo` (the time of the last input of any kind, system-wide, as
///   a tick count; nothing about what it was). Whether that input was the pointer or a key is
///   inferred, never observed: input with the cursor moved or a mouse button down is the pointer;
///   input with neither is the keyboard or the scroll wheel, which Windows does not tell apart
///   without a hook, so both count as typing (the typing guard then holds an offer while
///   reading with the wheel too, which only ever delays a nudge). Mouse buttons:
///   `GetAsyncKeyState` for the three buttons only.
/// - Display kept awake: the system's execution state (`CallNtPowerInformation`,
///   `SystemExecutionState`) has `ES_DISPLAY_REQUIRED` while any app asks for the display to stay
///   on (video, a presentation), or the shell reports presentation mode or a full-screen
///   Direct3D app (`SHQueryUserNotificationState`).
/// - Display mirrored: two active display paths share one source (`QueryDisplayConfig`).
/// - Microphone and camera: Windows' own record of which apps use them right now
///   (`HKCU\…\CapabilityAccessManager\ConsentStore\microphone|webcam`, an entry whose
///   `LastUsedTimeStop` is 0), watched with `RegNotifyChangeKeyValue`. Only whether any app does
///   is kept; the entries' names are never read beyond the walk.
/// - Presence: lock and unlock, remote connect and disconnect (`WTSRegisterSessionNotification`),
///   sleep and wake (`WM_POWERBROADCAST`), display off and on (`GUID_CONSOLE_DISPLAY_STATE`), and
///   the screensaver (`SPI_GETSCREENSAVERRUNNING`, read at each sample).
@MainActor
public final class WindowsActivityMonitor: ActivityMonitoring {
    public var onCallSignalsChange: ((CallSignals) -> Void)?
    public var onPresenceEvent: ((PresenceEvent) -> Void)?
    public private(set) var callSignals: CallSignals = []

    private var lastInputTick: DWORD = 0
    private var lastCursor = POINT()
    private var lastKeyAt = Date.distantPast
    private var lastPointerAt = Date()
    private var lastDragAt = Date.distantPast
    private var screensaverRunning = false
    private var locked = false
    private var displaysAsleep = false
    private var sessionActive = true
    private var classifier: Timer?
    private var started = false
    private var watchers: [ConsentWatcher] = []

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        SystemEvents.shared.start()
        var info = LASTINPUTINFO(cbSize: UINT(MemoryLayout<LASTINPUTINFO>.size), dwTime: 0)
        if GetLastInputInfo(&info) { lastInputTick = info.dwTime }
        GetCursorPos(&lastCursor)
        listenForPresence()
        callSignals = Self.readCallSignals()
        for capability in ["microphone", "webcam"] {
            let watcher = ConsentWatcher(capability: capability) { [weak self] in
                MainActor.assumeIsolated { self?.refreshCallSignals() }
            }
            watcher.start()
            watchers.append(watcher)
        }
        // Classify input often enough to tell typing from the pointer, but only while input is
        // recent: an idle machine wakes Breakpoint only for the coordinator's own tick.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.classify() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        classifier = timer
    }

    public func stop() {
        classifier?.invalidate()
        classifier = nil
        watchers.forEach { $0.stop() }
        watchers.removeAll()
        started = false
    }

    // MARK: Input

    /// Attributes any input since the last look to the pointer or the keyboard (see the type's
    /// documentation). Cheap: three calls, no allocation.
    private func classify() {
        var info = LASTINPUTINFO(cbSize: UINT(MemoryLayout<LASTINPUTINFO>.size), dwTime: 0)
        guard GetLastInputInfo(&info) else { return }
        var cursor = POINT()
        GetCursorPos(&cursor)
        let buttonDown = Self.mouseButtonDown
        let moved = cursor.x != lastCursor.x || cursor.y != lastCursor.y
        if info.dwTime != lastInputTick {
            let at = Date().addingTimeInterval(-Double(GetTickCount() &- info.dwTime) / 1000)
            if moved || buttonDown {
                lastPointerAt = at
                if buttonDown { lastDragAt = at }
            } else {
                lastKeyAt = at
            }
            lastInputTick = info.dwTime
        }
        lastCursor = cursor
    }

    public func sample() -> InputSample {
        classify()
        let now = Date()
        let sinceAny = Double(GetTickCount() &- lastInputTick) / 1000
        let running = Self.screensaverIsRunning
        if running != screensaverRunning {
            screensaverRunning = running
            onPresenceEvent?(running ? .screensaverStarted : .screensaverStopped)
        }
        return InputSample(takenAt: now,
                           secondsSinceKey: max(0, now.timeIntervalSince(lastKeyAt)),
                           secondsSinceAnyInput: max(0, sinceAny),
                           secondsSinceDrag: max(0, now.timeIntervalSince(lastDragAt)),
                           mouseButtonDown: Self.mouseButtonDown,
                           displaySleepPrevented: Self.displayKeptAwake,
                           secondsSinceScroll: 600,
                           displayMirrored: Self.displayMirrored)
    }

    static var mouseButtonDown: Bool {
        [VK_LBUTTON, VK_RBUTTON, VK_MBUTTON].contains { GetAsyncKeyState(Int32($0)) < 0 }
    }

    static var screensaverIsRunning: Bool {
        var running: WindowsBool = false
        _ = SystemParametersInfoW(UINT(SPI_GETSCREENSAVERRUNNING), 0, &running, 0)
        return running.boolValue
    }

    /// Some app keeps the display on, or the shell is in presentation or full-screen mode.
    static var displayKeptAwake: Bool {
        if bp_display_required() == 1 { return true }
        var notification = QUERY_USER_NOTIFICATION_STATE(rawValue: 0)
        if SHQueryUserNotificationState(&notification) == S_OK {
            return notification == QUNS_PRESENTATION_MODE || notification == QUNS_RUNNING_D3D_FULL_SCREEN
        }
        return false
    }

    /// Two active display paths share one source: a projector or second screen duplicating this one.
    static var displayMirrored: Bool {
        var pathCount: UINT32 = 0
        var modeCount: UINT32 = 0
        guard GetDisplayConfigBufferSizes(UINT32(QDC_ONLY_ACTIVE_PATHS), &pathCount, &modeCount) == ERROR_SUCCESS,
              pathCount > 1 else { return false }
        var paths = [DISPLAYCONFIG_PATH_INFO](repeating: DISPLAYCONFIG_PATH_INFO(), count: Int(pathCount))
        var modes = [DISPLAYCONFIG_MODE_INFO](repeating: DISPLAYCONFIG_MODE_INFO(), count: Int(modeCount))
        guard QueryDisplayConfig(UINT32(QDC_ONLY_ACTIVE_PATHS), &pathCount, &paths, &modeCount, &modes, nil) == ERROR_SUCCESS else {
            return false
        }
        var sources = Set<String>()
        for path in paths.prefix(Int(pathCount)) {
            let id = "\(path.sourceInfo.adapterId.HighPart):\(path.sourceInfo.adapterId.LowPart):\(path.sourceInfo.id)"
            if !sources.insert(id).inserted { return true }
        }
        return false
    }

    // MARK: Calls

    private func refreshCallSignals() {
        let signals = Self.readCallSignals()
        guard signals != callSignals else { return }
        callSignals = signals
        onCallSignalsChange?(signals)
    }

    static func readCallSignals() -> CallSignals {
        var signals: CallSignals = []
        if ConsentStore.inUse("microphone") { signals.insert(.microphone) }
        if ConsentStore.inUse("webcam") { signals.insert(.camera) }
        return signals
    }

    // MARK: Presence

    private func listenForPresence() {
        let events = SystemEvents.shared
        events.on(UInt32(WM_WTSSESSION_CHANGE)) { [weak self] wParam, _ in
            guard let self else { return nil }
            switch Int32(wParam) {
            case WTS_SESSION_LOCK: self.locked = true; self.onPresenceEvent?(.locked)
            case WTS_SESSION_UNLOCK: self.locked = false; self.onPresenceEvent?(.unlocked)
            case WTS_CONSOLE_DISCONNECT, WTS_REMOTE_DISCONNECT: self.sessionActive = false; self.onPresenceEvent?(.sessionResigned)
            case WTS_CONSOLE_CONNECT, WTS_REMOTE_CONNECT: self.sessionActive = true; self.onPresenceEvent?(.sessionActivated)
            default: break
            }
            return 0
        }
        events.on(UInt32(WM_POWERBROADCAST)) { [weak self] wParam, lParam in
            guard let self else { return nil }
            switch Int32(wParam) {
            case PBT_APMSUSPEND:
                self.onPresenceEvent?(.systemWillSleep)
            case PBT_APMRESUMEAUTOMATIC, PBT_APMRESUMESUSPEND:
                self.onPresenceEvent?(.systemDidWake)
            case PBT_POWERSETTINGCHANGE:
                guard let setting = UnsafePointer<POWERBROADCAST_SETTING>(bitPattern: Int(lParam)) else { break }
                if Self.sameGUID(setting.pointee.PowerSetting, GUID_CONSOLE_DISPLAY_STATE) {
                    // Data is one DWORD: 0 off, 1 on, 2 dimmed.
                    let value = UnsafeRawPointer(setting).advanced(by: MemoryLayout<POWERBROADCAST_SETTING>.offset(of: \.Data)!)
                        .load(as: DWORD.self)
                    if value == 0, !self.displaysAsleep {
                        self.displaysAsleep = true
                        self.onPresenceEvent?(.displaysSlept)
                    } else if value == 1, self.displaysAsleep {
                        self.displaysAsleep = false
                        self.onPresenceEvent?(.displaysWoke)
                    }
                }
            default:
                break
            }
            return LRESULT(1)
        }
    }

    // MARK: Diagnostics

    public func diagnosticReport() -> String {
        let sample = sample()
        let general = ActivityDiagnostics.report(sample: sample, audioDevices: [], cameraInUse: callSignals.contains(.camera),
                                                 locked: locked, displaysAsleep: displaysAsleep,
                                                 screensaverRunning: screensaverRunning, sessionActive: sessionActive, at: Date())
        var lines = general.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.hasPrefix("Audio devices:") && !$0.hasPrefix("  ") && !$0.hasPrefix("Microphone in use:") }
        let index = lines.firstIndex { $0.hasPrefix("Camera in use:") } ?? lines.count
        lines.insert("Microphone in use: \(callSignals.contains(.microphone) ? "yes" : "no") (an app has it open, from Windows' privacy settings; a call once on for \(Int(Timing.microphoneCallAfter)) s)", at: index)
        lines.append("Typing is inferred: input with the cursor still and no button down (keys or the wheel); no hook reads the keyboard")
        return lines.joined(separator: "\n")
    }
}

/// Windows' record of which apps use a capability now (Settings → Privacy & security →
/// Microphone / Camera show the same data).
enum ConsentStore {
    static let root = "Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\"

    /// Some app (packaged or not) has `capability` in use now.
    static func inUse(_ capability: String) -> Bool {
        anyInUse(under: root + capability, depth: 0)
    }

    private static func anyInUse(under path: String, depth: Int) -> Bool {
        var key: HKEY?
        guard RegOpenKeyExW(HKEY_CURRENT_USER, path.wide, 0, Registry.keyRead, &key) == ERROR_SUCCESS, let key else {
            return false
        }
        defer { RegCloseKey(key) }
        if depth > 0, isRunning(key) { return true }
        var index: DWORD = 0
        var name = [WCHAR](repeating: 0, count: 512)
        while true {
            var length = DWORD(name.count)
            let status = RegEnumKeyExW(key, index, &name, &length, nil, nil, nil, nil)
            if status != ERROR_SUCCESS { break }
            index += 1
            let child = String(decoding: name.prefix(Int(length)), as: UTF16.self)
            // Packaged apps are direct children; desktop apps live one level down under NonPackaged.
            if depth < 2, anyInUse(under: path + "\\" + child, depth: depth + 1) { return true }
        }
        return false
    }

    private static func isRunning(_ key: HKEY) -> Bool {
        func read(_ name: String) -> UInt64? {
            var value: UInt64 = 0
            var size = DWORD(MemoryLayout<UInt64>.size)
            let status = RegGetValueW(key, nil, name.wide, DWORD(RRF_RT_REG_QWORD), nil, &value, &size)
            return status == ERROR_SUCCESS ? value : nil
        }
        guard let start = read("LastUsedTimeStart"), let stop = read("LastUsedTimeStop") else { return false }
        return start > 0 && stop == 0
    }
}

/// Wakes the main thread when the consent store's subtree for one capability changes.
final class ConsentWatcher: @unchecked Sendable {
    let capability: String
    let changed: @Sendable () -> Void
    private var thread: Thread?
    private var stopEvent: HANDLE?

    init(capability: String, changed: @escaping @Sendable () -> Void) {
        self.capability = capability
        self.changed = changed
    }

    func start() {
        stopEvent = CreateEventW(nil, true, false, nil)
        let stopBits = UInt(bitPattern: stopEvent)
        let path = ConsentStore.root + capability
        let changed = changed
        let thread = Thread {
            var key: HKEY?
            guard RegOpenKeyExW(HKEY_CURRENT_USER, path.wide, 0, Registry.keyRead | Registry.keyNotify, &key) == ERROR_SUCCESS,
                  let key else { return }
            defer { RegCloseKey(key) }
            let event = CreateEventW(nil, false, false, nil)
            defer { CloseHandle(event) }
            var handles: [HANDLE?] = [event, HANDLE(bitPattern: stopBits)]
            while true {
                let filter = DWORD(REG_NOTIFY_CHANGE_LAST_SET | REG_NOTIFY_CHANGE_NAME)
                guard RegNotifyChangeKeyValue(key, true, filter, event, true) == ERROR_SUCCESS else { return }
                let result = WaitForMultipleObjects(2, &handles, false, INFINITE)
                if result != WAIT_OBJECT_0 { return }
                DispatchQueue.main.async { changed() }
            }
        }
        thread.name = "Breakpoint consent watcher (\(capability))"
        self.thread = thread
        thread.start()
    }

    func stop() {
        if let stopEvent { SetEvent(stopEvent) }
        thread = nil
    }
}

extension WindowsActivityMonitor {
    nonisolated static func sameGUID(_ a: GUID, _ b: GUID) -> Bool {
        withUnsafeBytes(of: a) { x in withUnsafeBytes(of: b) { y in x.elementsEqual(y) } }
    }
}

/// Registry access masks (composite macros Swift does not import).
enum Registry {
    static let keyRead = DWORD(0x2_0019)
    static let keyNotify = DWORD(0x0010)
}
