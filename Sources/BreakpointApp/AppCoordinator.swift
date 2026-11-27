import AppKit
import Combine
import os
import BreakpointCore
import BreakpointKit

/// SwiftUI's `Settings` scene type would make `Settings` ambiguous here; this target means Core's.
typealias Settings = BreakpointCore.Settings

let log = Logger(subsystem: BreakpointVersion.bundleIdentifier, category: "app")

/// The only place that knows about everything (SPEC §7.3). Owns the stores, the session tracker,
/// the clocks and policies' state, the system services, the socket server, the engine loop and
/// every window controller. Maps Core state into `AppState` and implements `AppActions`.
///
/// Files:
/// - `AppCoordinator.swift` — ownership, start and stop, wiring.
/// - `AppCoordinator+Loop.swift` — the engine loop: tick, events, presence, pauses, opportunities,
///   nudge and break lifecycles.
/// - `AppCoordinator+Actions.swift` — `AppActions` implementations.
/// - `AppCoordinator+State.swift` — Core → `AppState` mapping.
/// - `AppCoordinator+Commands.swift` — socket commands (`activate`, `signals`), the socket's
///   start-up problems, and (debug builds) the end-to-end harness: simulated signals, the
///   adjustable clock, headless recording surfaces and `breakpoint debug`.
@MainActor
final class AppCoordinator {
    // MARK: Environment

    let paths: BreakpointPaths
    let options: LaunchOptions
    /// Follows the system's time zone and calendar settings while the app runs (a laptop that
    /// changes time zone must move the 05:00 day boundary and the wind-down stop time with it).
    let calendar = Calendar.autoupdatingCurrent

    // MARK: Stores

    let settingsStore: SettingsStore
    let historyStore: HistoryStore
    let estimatorFile: JSONFile<RunLengthEstimator>

    // MARK: Core state (the coordinator's model; `AppState` is derived from it)

    var settings: Settings
    var tracker: SessionTracker
    var presence = PresenceTracker()
    var timers = TimerState.zero
    var pause = PauseState.none
    var detector = OpportunityDetector()
    /// An opportunity held by the typing guard, re-evaluated every tick until it expires.
    var heldOpportunity: Opportunity?
    var lastNudgeAt: Date?
    var lastBreakEndedAt: Date?
    var kindSpacedUntil: [BreakKind: Date] = [:]
    var consecutiveMoveRefusals = 0
    /// Eye-rest offers declined or ignored in a row (SPEC §2.4); only the coordinator needs it.
    var consecutiveEyeRefusals = 0
    /// After a breather the person started, no stretch-slot offer before this (SPEC §2.3).
    var stretchHeldUntil: Date?
    var currentDecision: AutoDecision?
    var windDown: WindDownState
    var nudge: NudgeState?
    /// When the eye-rest auto-start countdown reaches 0.
    var autoStartDeadline: Date?
    /// When the auto-start countdown began (key presses or clicks after this cancel it).
    var autoStartBegan: Date?
    var breakSession: BreakSession?
    /// The closing moment of the break that just completed (SPEC §3.3 Ending), shown until it ends.
    var completionMoment: CompletionMoment?
    /// Longest stretch without input during the current `walk` (for "Welcome back").
    var walkIdlePeak: TimeInterval = 0
    /// The AirPods check was started for the current break (and must be ended with it, even if
    /// the setting was switched off meanwhile).
    var motionCheckRunning = false
    /// Which routine and copy variants come next (`rotation.json`, SPEC §2.2).
    var rotation: RotationState
    /// The one-minute tour, while it runs (SPEC §3.12; `AppCoordinator+Tour.swift`).
    var tour: TourState?
    /// The sample break the tour started (records nothing).
    var tourBreakID: UUID?
    /// The real break that carries the first-break hint (SPEC §3.12).
    var breakHintID: UUID?
    /// The popover is open, and the first-use hint it carries this time, if any.
    var popoverOpen = false
    var popoverHint: String?
    /// When the popover last opened (the app's clock), and what closed it last, if not the mark,
    /// a command or the tour (SPEC §3.8).
    var popoverOpenedAt: Date?
    var popoverClosedBy: PopoverCloseCause?
    /// The menu-bar mark's latest one-shot movement (SPEC §3.7).
    var markCue: MarkCueEvent?
    /// A run finished normally since the last `publish` (the mark's settle movement).
    var runFinishedSincePublish = false
    var cards: [CardState] = []
    /// Agent sessions that finished or needed the user while the user was away.
    var resumeWhileAway: [SessionKey] = []
    /// Long shell commands that ended during a break or while away, by shell (source `shell`, the
    /// PID as session id), until the resume card shows them (SPEC §3.5).
    var finishedCommands: [SessionKey: ResumeFacts] = [:]
    var lastEventBySource: [AgentSource: Date] = [:]
    var integrationStates: [IntegrationID: IntegrationInstallState] = [:]
    var integrationNotes: [IntegrationID: [String]] = [:]
    var integrationErrors: [IntegrationID: String] = [:]
    var integrationBusy: Set<IntegrationID> = []
    /// Install checks under way (`InstallCheck`): the `test` event that proves one is awaited.
    var installChecks: [IntegrationID: UUID] = [:]
    /// What an install check found wrong (until the next install or a real event from the tool).
    var installCheckProblems: [IntegrationID: String] = [:]
    /// What `InstallCheck` finds wrong on disk, from the latest re-read of install states.
    var installDiskProblems: [IntegrationID: String] = [:]
    /// When this run's install check passed (the row's ✓ plays its movement once).
    var integrationConnectedAt: [IntegrationID: Date] = [:]
    /// Still time has counted only since launch: no break or time away reset it yet (the popover
    /// then says so instead of "since you moved").
    var stillCountedSinceLaunch = true
    var lastPublishedStillTime: TimeInterval = 0
    var todaySummary: DaySummary
    /// All-time totals for the popover: scanned once at launch, then kept by `record`.
    var totals = HistoryTotals.empty
    var lastSample: InputSample
    var lastTick: Date
    var lastCallSignals: CallSignals = []
    /// A microphone counts as a call only after `Timing.microphoneCallAfter` on (SPEC §2.4).
    var microphoneGate = MicrophoneCallGate()
    /// Added to the wall clock (debug harness only: `breakpoint debug advance|jump`; 0 otherwise).
    var clockOffset: TimeInterval = 0
    /// Why the socket could not be opened, if it could not (one sentence; shown once).
    var socketProblem: String?
    /// When the integration states were last read from disk.
    var integrationsRefreshedAt: Date?
    /// The update check's memory (`updates.json`, SPEC §2.11).
    var updateRecord: UpdateRecord
    /// A check is on its way.
    var updateChecking = false
    /// No automatic check in the first minutes after this.
    let launchedAt: Date
    /// An in-place update in progress, and whether it started by itself.
    var updateInstallStep: UpdateInstallStep?
    var updateInstallIsAutomatic = false
    /// Why the last install stopped (About and the card).
    var updateInstallFailure: String?
    /// The debug harness's stand-ins: an app bundle to replace, a throwaway key, and running the
    /// install work on the main thread so each step finishes within one command.
    var updateLocationOverride: URL?
    var updateKeyOverride: String?
    var updateWorkIsSynchronous = false
    #if DEBUG
    /// The end-to-end harness (debug builds only).
    var harness: DebugHarness?
    /// Added to the install check's environment (`breakpoint debug install-check unreachable`).
    var debugInstallCheckEnvironment: [String: String] = [:]
    #endif

    // MARK: Kit

    let state: AppState
    private(set) var actions = AppActions.noop
    let monitor: ActivityMonitoring
    let headphones: HeadphoneMotionMonitoring
    let sound: SoundPlaying
    let loginItem: LoginItemControlling
    let hotKeys = HotKeyCenter()
    let focusRestorer = FocusRestorer()
    let watchdog: OverlayWatchdog
    let panelStack: TransientPanelStack
    /// The app's only network access: the release feed (SPEC §2.11).
    let updateFetcher: UpdateFetching

    // MARK: Controllers

    // All nil when windows are suppressed (`--debug-headless`).
    private(set) var statusItem: StatusItemController?
    private(set) var settingsWindow: SettingsWindowController?
    private(set) var onboarding: OnboardingWindowController?
    private(set) var overlay: BreakOverlayController?
    private(set) var surfaces: [SurfaceController] = []

    // MARK: Wire and loop

    let server: EventSocketServer
    private var tickTimer: Timer?
    private var tickInterval: TimeInterval = 0
    private var stateObservation: AnyCancellable?
    private var syncScheduled = false

    init(paths: BreakpointPaths, options: LaunchOptions, now: Date = Date()) {
        self.paths = paths
        self.options = options
        settingsStore = SettingsStore(paths: paths)
        historyStore = HistoryStore(paths: paths, calendar: .autoupdatingCurrent)
        estimatorFile = RunLengthEstimator.file(paths)
        rotation = RotationState.load(paths)

        let settings = settingsStore.load()
        self.settings = settings
        tracker = SessionTracker(estimator: RunLengthEstimator.load(paths), storePromptSnippets: settings.storePromptSnippets)
        windDown = WindDownState(dayStart: BreakpointDay.start(of: now))
        todaySummary = DaySummary(dayStart: BreakpointDay.start(of: now))
        lastSample = InputSample.quiet(at: now)
        lastTick = now
        launchedAt = now
        updateRecord = UpdateRecord.load(paths)

        state = AppState(settings: settings, now: now)
        #if DEBUG
        let harness = DebugHarness(options: options.debug)
        self.harness = harness
        monitor = harness.monitor ?? ActivityMonitor()
        headphones = harness.headphones ?? HeadphoneMotionMonitor()
        sound = harness.sound ?? SoundPlayer()
        // The harness never touches the network: its feed is a local file or a simulated failure.
        updateFetcher = harness.updateFetcher ?? UpdateFetcher()
        #else
        monitor = ActivityMonitor()
        headphones = HeadphoneMotionMonitor()
        sound = SoundPlayer()
        updateFetcher = UpdateFetcher()
        #endif
        loginItem = LoginItem()
        watchdog = OverlayWatchdog(logURL: paths.watchdogLog, appURL: Bundle.main.bundleURL)
        let settingsForStack = { [weak state] in state?.settings.popupPosition ?? .topCentre }
        panelStack = TransientPanelStack(position: settingsForStack)
        server = EventSocketServer(socketPath: SocketPath(paths: paths))

        actions = makeActions()
        makeControllers()
        #if DEBUG
        harness.attach(to: self)
        #endif
    }

    /// The coordinator's clock: the wall clock, plus the debug harness's offset (0 in release).
    func currentDate() -> Date {
        Date().addingTimeInterval(clockOffset)
    }

    /// True when real windows are suppressed (`--debug-headless`, debug builds only).
    var isHeadless: Bool {
        #if DEBUG
        return options.debug.headless
        #else
        return false
        #endif
    }

    // MARK: Lifecycle

    func start() {
        // The socket first: if another copy of Breakpoint already answers on it, hand over to that
        // copy and quit before showing anything (§5.1).
        server.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        server.statusProvider = { [weak self] in
            MainActor.assumeIsolated { self?.statusReport() ?? StatusReport(generatedAt: Date()) }
        }
        server.commandHandler = { [weak self] name, arguments in
            MainActor.assumeIsolated { self?.handleCommand(name, arguments: arguments) ?? "" }
        }
        notePendingUpdateLaunch()
        do {
            try server.start()
        } catch SocketServerError.alreadyRunning {
            handOverToRunningCopy()
            return
        } catch {
            socketProblem = Self.describeSocketProblem(error)
            log.error("Socket server did not start: \(String(describing: error), privacy: .public)")
        }

        stateObservation = state.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }

        statusItem?.install()

        monitor.onCallSignalsChange = { [weak self] _ in self?.tick() }
        monitor.onPresenceEvent = { [weak self] event in self?.handlePresenceEvent(event) }
        monitor.start()

        refreshCLICopy()
        refreshIntegrations()
        refreshToday()
        refreshTotals()
        applyLoginItemDefault()
        #if DEBUG
        harness?.didStart()
        #endif
        publish()
        scheduleTick(interval: 1)

        if !settings.hasCompletedOnboarding || options.forceOnboarding {
            onboarding?.show()
            recordSurface("onboarding shown")
        } else if options.startTour {
            // `--tour`: the tour at once, as Settings → General → Take the tour would start it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.replayTour() }
        }
        if let socketProblem { reportSocketProblem(socketProblem) }
        settlePendingUpdate()
        publish()
        log.info("Breakpoint \(BreakpointVersion.current, privacy: .public) started")
        if let statusItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak statusItem] in
                let frame = statusItem?.statusItemFrame.map { "\($0)" }
                    ?? "none (hidden by macOS: \(statusItem?.visibilityDiagnostics ?? "no item"))"
                let policy = NSApp.activationPolicy() == .accessory ? "accessory" : "regular"
                log.info("Status item frame: \(frame, privacy: .public); activation policy: \(policy, privacy: .public)")
            }
        }
        if let seconds = options.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }

    func stop() {
        if tour != nil { endTour(.interrupted(.appQuit), now: currentDate()) }
        tickTimer?.invalidate()
        tickTimer = nil
        server.stop()
        monitor.stop()
        hotKeys.unregisterAll()
        watchdog.stop()
        saveEstimator()
        surfaces.forEach { $0.tearDown() }
        panelStack.dismissAll()
        log.info("Breakpoint stopped")
    }

    func showPopover() {
        statusItem?.showPopover()
        recordSurface("popover shown")
        // Headless there is no popover to say it opened (the real one does, through its delegate).
        if statusItem == nil { popoverVisibilityChanged(true) }
    }

    // MARK: Wiring

    private func makeControllers() {
        if isHeadless {
            #if DEBUG
            if let harness { surfaces = [harness.recorder] }
            #endif
        } else {
            let statusItem = StatusItemController(state: state, actions: actions)
            statusItem.hotKeys = hotKeys
            let settingsWindow = SettingsWindowController(state: state, actions: actions)
            let onboarding = OnboardingWindowController(state: state, actions: actions)
            let overlay = BreakOverlayController(state: state, actions: actions, focusRestorer: focusRestorer, watchdog: watchdog)
            overlay.debugStallSeconds = options.debugStallMain
            self.statusItem = statusItem
            self.settingsWindow = settingsWindow
            self.onboarding = onboarding
            self.overlay = overlay
            surfaces = [
                statusItem,
                NudgePanelController(state: state, actions: actions, stack: panelStack, hotKeys: hotKeys),
                CountdownChipController(state: state, stack: panelStack),
                overlay,
                ResumeCardController(state: state, actions: actions, stack: panelStack, hotKeys: hotKeys),
                AwayNoteController(state: state, actions: actions, stack: panelStack),
                ToastController(state: state, actions: actions, stack: panelStack),
                WindDownCardController(state: state, actions: actions, stack: panelStack),
                UpdateCardController(state: state, actions: actions, stack: panelStack),
                TourCoachController(state: state, actions: actions, stack: panelStack, hotKeys: hotKeys),
                settingsWindow,
                onboarding,
            ]
            #if DEBUG
            // With windows shown, the recorder only traces (the real controllers own the timers).
            if let harness, options.debug.trace { surfaces.append(harness.recorder) }
            #endif
        }
        panelStack.onEvicted = { [weak self] id in
            guard let self else { return }
            // A pop-up pushed out by a higher-priority one is gone for good (SPEC §3.0).
            if self.nudge?.id == id {
                self.nudge = nil
            } else {
                self.cards.removeAll { $0.id == id }
            }
            self.publish()
        }
    }

    /// Notes what a suppressed or real surface did, for the debug trace (no-op in release).
    func recordSurface(_ line: String) {
        #if DEBUG
        harness?.recorder.note(line)
        #endif
    }

    /// Runs every controller's `sync()` now (the debug harness steps the clock synchronously).
    func syncSurfacesNow() {
        surfaces.forEach { $0.sync() }
    }

    /// Coalesces state changes into one `sync()` per run-loop turn.
    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.surfaces.forEach { $0.sync() }
        }
    }

    /// 1 Hz normally; 10 Hz while a nudge or the countdown chip is visible (SPEC §2.4).
    func scheduleTick(interval: TimeInterval) {
        guard interval != tickInterval || tickTimer == nil else { return }
        tickInterval = interval
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    // MARK: Persistence helpers

    /// Before onboarding: "Open at login" starts off when this copy cannot register it (outside an
    /// Applications folder), so the Done step and Settings never show a choice that does nothing
    /// (§3.10).
    private func applyLoginItemDefault() {
        guard !settings.hasCompletedOnboarding, settings.launchAtLogin, LoginItem.availability().defaultsToOff else { return }
        settings.launchAtLogin = false
        saveSettings()
    }

    func saveSettings() {
        do {
            try settingsStore.save(settings)
        } catch {
            log.error("Could not save settings: \(String(describing: error), privacy: .public)")
        }
    }

    func saveEstimator() {
        do {
            try estimatorFile.write(tracker.estimator)
        } catch {
            log.error("Could not save sessions.json: \(String(describing: error), privacy: .public)")
        }
    }

    func record(_ entry: HistoryEntry) {
        do {
            try historyStore.append(entry)
            totals.add(entry)
        } catch {
            log.error("Could not append history: \(String(describing: error), privacy: .public)")
        }
        refreshToday()
    }

    /// Counts the all-time totals from the whole file (launch, Undo, Delete all data).
    func refreshTotals() {
        do {
            totals = try historyStore.totals()
        } catch {
            log.error("Could not read history totals: \(String(describing: error), privacy: .public)")
        }
    }

    func refreshToday() {
        let now = currentDate()
        if let summary = try? historyStore.summary(forDayContaining: now) {
            todaySummary = summary
        }
    }

    /// Refreshes `~/.breakpoint/bin/breakpoint` when an installed copy has another version (SPEC §5.2).
    private func refreshCLICopy() {
        guard let bundled = bundledCLI else { return }
        let installer = CLIInstaller(paths: paths, bundledCLI: bundled)
        DispatchQueue.global(qos: .utility).async {
            guard installer.isInstalled, installer.needsRefresh() else { return }
            do {
                try installer.install()
            } catch {
                log.error("Could not refresh the CLI copy: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The CLI to copy to `~/.breakpoint/bin`: the bundled one (Contents/Helpers/breakpoint) when
    /// running from the app bundle, else (a development build in `.build/…`) the `breakpoint`
    /// built next to the app's executable.
    var bundledCLI: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/breakpoint")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        guard let executable = Bundle.main.executableURL, Bundle.main.bundleURL.pathExtension != "app" else { return nil }
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("breakpoint")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    var integrationEnvironment: IntegrationEnvironment {
        IntegrationEnvironment(paths: paths, codexHomeOverride: settings.codexHome,
                               processEnvironment: ProcessInfo.processInfo.environment)
    }

    /// Re-reads every integration's install state off the main thread.
    func refreshIntegrations() {
        integrationsRefreshedAt = Date()
        let environment = integrationEnvironment
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var states: [IntegrationID: IntegrationInstallState] = [:]
            var problems: [IntegrationID: String] = [:]
            for id in IntegrationID.allCases {
                let state = IntegrationRegistry.integration(id, environment: environment).status()
                states[id] = state
                problems[id] = InstallCheck.problem(for: id, state: state, environment: environment)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.integrationStates = states
                    self.installDiskProblems = problems
                    // Relayed Cursor events (via Claude Code's hooks) are duplicates only while
                    // Breakpoint's own Cursor hooks are in place, in any version (§2.6, §5.4).
                    self.tracker.nativeCursorInstalled = states[.cursor]?.hasBreakpointEntries == true
                    self.publish()
                }
            }
        }
    }
}
