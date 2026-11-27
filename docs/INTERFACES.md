# Interfaces

Every seam between the four parts of the code, with where it lives and what implements or consumes
it. The doc comment on each type is the contract; this page is the map. Behaviour is specified in
[SPEC.md](SPEC.md); commands and conventions are in [../CLAUDE.md](../CLAUDE.md).

## How the pieces talk

```
agent hook ─▶ breakpoint emit ─▶ socket ─▶ EventSocketServer ─▶ AppCoordinator
                                                                 │  uses the Core policies
ActivityMonitor ─▶ InputSample / CallSignals / PresenceEvent ───▶│
                                                                 ▼
                   AppState ◀── publish()     AppActions ◀── views (break screens, menu bar, settings)
                      │
           SurfaceController.sync() ─▶ controllers ─▶ windows and panels
```

- Core is pure: policies take values and return values. The coordinator owns all mutable state
  and calls them (`Sources/BreakpointApp/AppCoordinator+Loop.swift` shows every call site).
- Views read only `AppState` and Core models and express intents only through `AppActions`.
- Controllers are created once by the coordinator and reconcile their windows in `sync()`.

## Shared models (Sources/BreakpointCore/Models)

| Type | File | Notes |
|---|---|---|
| `AgentSource`, `AgentEvent`, `AgentEventKind` | AgentSource.swift, AgentEvent.swift | wire keys and nulls per SPEC §6 |
| `AgentSession`, `AgentState`, `SessionKey`, `RunEnding`, `RunningCommand` | AgentSession.swift | |
| `BreakKind`, `BreakOutcome`, `BreakFinishReason` | BreakKind.swift | `walkTarget`, `allowsExtension`, `weight` |
| `Opportunity`, `OpportunityKind` | Opportunity.swift | expires after 30 s |
| `BreakOffer`, `EngineDecision`, `HoldReason`, `SuppressReason` | EngineDecision.swift | |
| `PauseReason`, `PauseState`, `CallSignals`, `PauseDuration` | Pause.swift | |
| `InputSample`, `PresenceEvent`, `PresenceStatus`, `AwayCause`, `AwayPeriod` | Presence.swift | `isTyping` / `isPointerBusy` = the typing guard; `presentingCause` (Engine/PresentingGuard.swift) = the presenting guard |
| `PresentingCause`, `AutoStartRules` | Engine/PresentingGuard.swift | when an eye rest may count down and what cancels it |
| `MicrophoneCallGate` | Tracking/MicrophoneCallGate.swift | coordinator (`microphoneGate`): raw call signals → counted ones; `EngineSnapshot.microphonePending` |
| `TimerState`, `AutoDecision` | TimerState.swift | |
| `EngineSnapshot` | EngineSnapshot.swift | everything the engine may read |
| `BreakSession`, `WindDownState` | BreakSession.swift | coordinator-held break and night state |
| `Settings`, `MenuBarTextMode`, `PopupPosition`, `HotKeyCombo` | Settings.swift | tolerant decoding, `normalized()`, `setCadence`, `applyPreset` |
| `Cadence`, `CadencePreset` | Cadence.swift | |
| `Routine`, `RoutineStep`, `TempoPhase`, `RoutineEquipment`, `BreakCopy` | Routine.swift | content lives in `Routines/` |
| `HistoryEntry`, `DaySummary` | History.swift | `DaySummary.summarize` |
| `HistoryTotals` | History/HistoryTotals.swift | App (`totals`, kept by `record`), popover via `AppState.totals` |
| `MovingExamples`, `TotalsCopy` | Routines/ | Popover totals section, debug state |
| `IntegrationID`, `IntegrationInstallState` (incl. `outdated`, `modified`, `hasBreakpointEntries`), `IntegrationStatus` | IntegrationModels.swift | |
| `WireMessage` (`event`, `statusRequest`, `statusReply`, `command(name:arguments:)`, `reply`), `StatusReport` (with `nextBreak`, `activeBreak`, `nudge`, `Session.runStartedAt` for the status line; all optional), `WireError` | WireMessage.swift | encode/decode tested |
| `BreakpointPaths`, `PathDisplay` | Paths.swift | injectable home; `BREAKPOINT_HOME` override |
| `BreakpointDay`, `TimeOfDay`, `Weekdays` | Calendar.swift | 05:00 day boundary |
| `Timing` | Timing.swift | every behavioural constant of SPEC §2–3 |
| `DurationFormat`, `TimeFormat`, `TextFormat` | Formatting.swift | shared formatting |
| `JSONFile`, `ISO8601` | JSONFile.swift | atomic JSON files |
| `BreakpointVersion` | Version.swift | read by build-app.sh and the CLI |
| `MarkCue`, `MarkCueEvent`, `MarkPose`, `MarkMotion`, `MarkFacts`, `MarkCuePolicy` | MarkMotion.swift | the menu-bar mark's one-shot movements (`MenuBarState.cue`) |
| `TourStep`, `TourPopoverPart`, `TourOrigin`, `TourInterruption`, `TourEnding`, `TourStatus`, `TourState`, `TourInput`, `TourTransition`, `TourCoach` | Tour.swift | the one-minute tour (SPEC §3.12); `Settings.tourStatus` remembers it |
| `HintSurface`, `HintLesson` (`surface`) | Hint.swift | first-use hints (SPEC §3.12); `Settings.showHints`, `Settings.hintsSeen` (lessons known) |

## Core logic

| Interface | File | Consumed by |
|---|---|---|
| `BreakEngine.decide(_:opportunity:now:) -> EngineDecision` | Engine/BreakEngine.swift | App loop |
| `BreakEngine.spacingAfterRefusal(_:refusalsInARow:cadence:) -> TimeInterval` | Engine/BreakEngine.swift | App loop (kind spacing after Not now or an ignored nudge) |
| `OpportunityDetector.evaluate(_:now:) -> [Opportunity]` | Engine/OpportunityDetector.swift | App loop |
| `CommandDenylist` | Engine/OpportunityDetector.swift | detector |
| `AwayPolicy.resolve(_:timers:settings:now:) -> AwayResolution`, `undo(_:)` | Engine/AwayPolicy.swift | App loop, Undo |
| `PausePolicy.update / pause / wrapUp / resumeNow / startCooldown` | Engine/PausePolicy.swift | App loop, actions |
| `WindDownPolicy.shouldOfferCard / holdDuration / extend / wrapUp / rolledOver / wrapUpNote` | Engine/WindDownPolicy.swift | App loop, actions |
| `BreakSessionRules` | Engine/BreakSessionRules.swift | App loop, previews |
| `WhyNotNow.explain(_:held:onBreak:now:) -> WaitReason`, `Copy.whyNotNow` | Engine/WhyNotNow.swift, Routines/Copy+Charm.swift | `StatusState.whyNotNow` (popover, option-click), debug state |
| `BackdropTimeline.entrance(at:) / exit(at:) -> BackdropFrame`, `AuroraField.lights(phase:bloom:)` (pure; the overlay backdrop's layers and lights) | Engine/OverlayAtmosphere.swift | `OverlayFrame`, `OverlayBackdrop` |
| `SessionTracker.apply(_:now:) -> TrackerUpdate`, `expire(now:)`, `SessionTransition` | Tracking/SessionTracker.swift | App loop |
| `RunLengthEstimator.record / expectedRunLength / load(paths)` (persisted to sessions.json) | Tracking/SessionTracker.swift | tracker, engine snapshot, App start |
| `ActivityClock.advance / afterBreak`, `removingAccrual` | Tracking/ActivityClock.swift | App loop |
| `PresenceTracker.ingest(sample…) / ingest(event…) -> [PresenceChange]` | Tracking/ActivityClock.swift | App loop |
| `HistoryStore.append / entries / allEntries / delete / summary / totals / export / deleteAll` | History/HistoryStore.swift | App (debug state reads `allEntries`) |
| `SettingsStore.load / save` (`save` returns a `SettingsChange`; `onChange`), `SettingsChange` | Settings/SettingsStore.swift, SettingsChange.swift | App (`updateSettings` uses `SettingsChange`), CLI |
| `LoginItemAvailability.evaluate(bundlePath:isAppBundle:environment:)` (pure: a login item only from an Applications folder; `allowsRegistering`, `allowsUnregistering`, `defaultsToOff`) | Settings/LoginItemAvailability.swift | `LoginItem` (Kit), App start (the first launch's default) |
| `BuiltInRoutines`, `BreakCopyLibrary`, `Copy` (the content) | Routines/ | every screen |
| `TourPolicy.start / apply / status(during:) / status(after:) / offersAfterOnboarding / opensPopoverAfter`, sample data (`sampleAgent`, `sampleResume`, …); `TourCopy` (coach lines) | Engine/TourPolicy.swift, Routines/TourCopy.swift | App (`AppCoordinator+Tour.swift`), tour views |
| `PopoverPolicy.closes(for:context:)`, `PopoverPolicy.Context`, `PopoverCloseCause` (what closes the popover, SPEC §3.8) | Engine/PopoverPolicy.swift | App (`AppCoordinator+Hints.swift`), debug state |
| `HintPolicy.shows / markingShown / markingTaught / taught(leaving:for:) / nudgeLesson / resumeLesson / pending / showsCallPauseToast`, `HintPolicy.Context`; `HintCopy` (the lines) | Engine/HintPolicy.swift, Routines/TourCopy.swift | App (`AppCoordinator+Hints.swift`), debug state |
| `RotationState`, `RoutineRotation`, `CopyRotation` (per-kind and named bags), `RoutineReplay` (`rotation.json`, "1 more minute"), `TempoPacing` (the `move` pace ring), closing lines and walk ideas (`BreakEndingCopy.swift`) | Routines/ | coordinator (`AppCoordinator+Rotation.swift`) |
| `ActivityMonitoring` / `ActivityMonitor` (`diagnosticReport()`), `ActivityDiagnostics.report`, `MicrophoneUse` | Kit Services/ActivityMonitor.swift, Tracking/MicrophoneUse.swift | App (`--signals`, `signals` command → `breakpoint doctor`) |
| `HeadphoneMotionMonitoring` / `HeadphoneMotionMonitor` (`prepare(enabled:)` every tick and on the setting's change; `begin`, `end`) | Kit Services/HeadphoneMotionMonitor.swift | App |

## Integrations

| Interface | File | Consumed by |
|---|---|---|
| `SocketPath` | Wire/SocketPath.swift | server, client |
| `EventSocketServer` (`start` throws `SocketServerError.alreadyRunning / pathOccupied / pathTooLong / system`; `stop`, `onEvent`, `statusProvider`, `commandHandler`; delivers on the main queue) | Wire/EventSocketServer.swift | App |
| `EventSocketClient.send / request` | Wire/EventSocketClient.swift | CLI, App (second-copy hand-over) |
| `Integration` protocol, `IntegrationEnvironment`, `InstallReport`, `IntegrationError`, `IntegrationRegistry` | Integrations/Integration.swift | App, CLI |
| `InstallCheck` (the check after Install: `problem`, `toolProblem`, `hookProcess`, `cliRuns`, `unreachableProblem`) | Integrations/Integration.swift | App (after Install, on every re-read of install states), CLI doctor (`toolProblem`) |
| `ClaudeCodeIntegration`, `CursorIntegration`, `CodexIntegration`, `CodexNotifyIntegration`, `CopilotIntegration`, `GeminiIntegration`, `ShellIntegration` | Integrations/ToolIntegrations.swift | registry |
| `JSONSettingsMerger`, `MarkerBlockEditor`, `CLIInstaller` | Integrations/FileEditing.swift | installers, App, CLI |
| `EmitRequest`, `HookPayloadParser.event / cleanTitle` | Integrations/HookPayloadParser.swift | CLI |
| `IntegrationLedger` (`integrations.json`, internal) | Integrations/ConfigFile.swift | installers; kept by Delete all data |
| `StatusLine` (`parts`, `render(_:colour:)`: the `status --line` grammar and colours, from a `StatusReport`), `TerminalMark` (`--version`'s mark; its colour detection is shared) | Wire/StatusLine.swift, Integrations/TerminalMark.swift | CLI |
| CLI: `CLIArguments`, `Emit`, `Commands` (`doctor` prints the app's signal report; `debug` in debug builds), `StatusLineCommand` | Sources/breakpoint-cli | hooks, users, prompts and status bars, scripts/e2e.sh |

Consumes: `WireMessage`, `AgentEvent`, `StatusReport`, `BreakpointPaths`, `IntegrationID`.

## Break screens

All controllers conform to `SurfaceController` (State/SurfaceController.swift) and are created by
the coordinator with `(state:actions:…)`.

| Interface | File | Reads from AppState | Calls in AppActions |
|---|---|---|---|
| `TransientPanelStack` (`present`, `dismiss`, `dismissAll`, `relayout`, `onEvicted`, `handOff` / `takeHandoff` / `cardFrame`), `TransientPanel`, `PopupHandoff` | Break/TransientPanelStack.swift | `settings.popupPosition` | — |
| `NudgePanelController`, `NudgeCardView` | Break/Nudge*.swift | `nudge` | `acceptNudge`, `declineNudge`, `ignoreNudge`, `cancelAutoStart` |
| `CountdownChipController` (takes the nudge card from the stack), `CountdownChipView`, `NudgeChipMorphView` | Break/CountdownChip*.swift | `nudge` (phase `.countdownChip`) | — |
| `BreakOverlayController` (`debugStallSeconds`), `BreakOverlayView`, `OverlayBackdrop` | Break/BreakOverlay*.swift, Break/OverlayBackdrop.swift | `activeBreak`, `now` | `skipBreak`, `finishBreak`, `extendBreak`, `stepRoutine` |
| `EyesBreakView`, `MoveBreakView`, `RoutinePlayerView`, `WalkBreakView`, `BreatheBreakView` | Break/*BreakView.swift | `activeBreak` | — |
| `ResumeCardController`, `ResumeCardView` | Break/ResumeCard*.swift | `cards` (`.resume`) | `dismissCard` |
| `AwayNoteController`, `AwayNoteView` | Break/AwayNote*.swift | `cards` (`.awayNote`) | `undoLastDecision`, `dismissCard` |
| `ToastController`, `ToastView` | Break/Toast*.swift | `cards` (`.toast`) | `resume`, `dismissCard` |
| `WindDownCardController`, `WindDownCardView` | Break/WindDownCard*.swift | `cards` (`.windDown`) | `windDownExtend`, `windDownWrapUp`, `copyWrapUpNote`, `dismissCard` |
| `SoundPlaying` / `SoundPlayer` | Break/SoundPlayer.swift | — | used by App |
| `FocusRestorer` | Break/FocusRestorer.swift | — | used by the overlay controller |
| `OverlayWatchdog` | Break/OverlayWatchdog.swift | — | used by the overlay controller |
| `HotKeyCenter`, `HotKeyToken` | Services/HotKeyCenter.swift | — | used by the nudge, the resume card (⌃⌥⌘. at a lower priority, sharing the key) and the popover shortcut |
| `ActiveDisplay.screen()`, `popupTopEdge(on:)` | Services/ActiveDisplay.swift | — | stack, chip, overlay |
| `TransientPanelStack.presentHanging(_:id:below:)`, `hangingPlacement(cardWidth:anchor:on:)` | Break/TransientPanelStack.swift | — | the tour's coach card under the mark (outside the stack's limit) |

### The one-minute tour and first-use hints (SPEC §3.12)

| Interface | File | Reads from AppState | Calls in AppActions |
|---|---|---|---|
| `TourCoachController` (the offer, the mark, Not now's result, the farewell; ⌃⌥⌘B / ⌃⌥⌘. while shown), `TourCoachCard` | Tour/TourCoachController.swift | `tour`, `StatusItemController.current?.statusItemFrame` | `tour(.next)`, `tour(.skip)` |
| The coach family: `CoachDot` (the coach mark), `CoachStem`, `HintLine` (pop-ups, popover), `OverlayCoachLine` (break screen: the tour's lines and the first-break hint) | Design/CoachLine.swift | — | — |
| `CoachCaption`, `CoachPointer`, `TourProgressDots`, `MarkLegend`, `TourAttachedCaption` (under the sample nudge and resume card) | Tour/CoachCaption.swift | `tour` | `tour` |
| `TourPopoverStrip`, `.tourSpotlight(_:tour:)` | Tour/TourPopover.swift | `tour` (step `popover`) | `tour(.next)`, `tour(.skip)` |
| Sample surfaces: `NudgeState.isRehearsal` (no ignore timer, coach line underneath), `ActiveBreakState.isRehearsal` (coach lines, Rehearsal footer), `CardState.isRehearsal` (never hides itself) | Break/NudgePanelController.swift, BreakOverlayView.swift, ResumeCardController.swift, CardPanelSurface.swift (`makeAccessory`) | `nudge`, `activeBreak`, `cards` | `acceptNudge`, `declineNudge`, `skipBreak`, `dismissCard` (the coordinator routes them to the tour) |
| Hints on real surfaces: `NudgeState.hint`, `ActiveBreakState.hint`, `ResumeCardContent.hint`, `ToastContent.hint` (such a toast stays `Timing.cardAutoHide`), `AppState.popoverHint` | NudgeCardView, BreakOverlayView, ResumeCardView, ToastView, PopoverView | those fields | — (a hint takes no click) |
| Settings → General → Getting started: Take the tour, Show hints | Settings/GeneralPane.swift | `settings` | `replayTour`, `updateSettings` |

## Menu bar, settings, onboarding

| Interface | File | Reads from AppState | Calls in AppActions |
|---|---|---|---|
| `StatusItemController` (`install`, `showPopover`, `togglePopover`, `closePopover`, `statusItemFrame`) | MenuBar/StatusItemController.swift | `menuBar`, `tour` | `startBreak`, `pause`, `openSettings`, `quit`, `popoverVisibilityChanged` (opened / closed, however; the coordinator moves the tour on when it closes), `popoverMayClose` (a click outside, Esc, another app, a Space or display change, the menu bar sliding away), `tour(.next)` (Return during the tour) |
| `PopoverView` | MenuBar/PopoverView.swift | `status`, `lastDecision`, `sessions`, `commands`, `totals`, `now`, `tour`, `popoverHint` | `startBreak`, `pause`, `resume`, `undoLastDecision`, `openSettings`, `quit` |
| `AppIconView` | MenuBar/AppIconView.swift | — | rendered by `BreakpointSnapshots --app-icon` |
| `SettingsWindowController` (`show(pane:)`), `SettingsPane`, `SettingsSelection`, `SettingsRootView`, `SettingsPaneView` | Settings/SettingsWindowController.swift, SettingsRootView.swift | `settings`, `integrations` | `updateSettings`, `install`, `uninstall`, `previewNudge`, `previewBreak`, `previewSound`, `exportHistory`, `deleteAllData` |
| One view per pane: `BreaksPane`, `RoutinePane`, `PausesPane`, `WindDownPane`, `IntegrationsPane`, `GeneralPane`, `PrivacyPane`, `AboutPane` | Settings/*Pane.swift | | |
| `OnboardingWindowController` (`show`), `OnboardingStep`, `OnboardingView`, `WelcomeStep`, `HowItWorksStep`, `ConnectStep`, `PaceStep`, `DoneStep` | Onboarding/ | `integrations`, `settings` | `install`, `updateSettings`, `completeOnboarding` |
| `LoginItemControlling` / `LoginItem` (`availability()`, `status`; registers only where `LoginItemAvailability` allows) | Services/LoginItem.swift | — | used by App, General pane, Done step |

## Shared Kit

| Interface | File |
|---|---|
| `AppState` (fields of SPEC §7.2 + `now`, `tour`, `popoverHint`), `PreviewScenario`, `AppState.preview(_:)`, `PreviewData` | State/AppState.swift, State/AppState+Preview.swift |
| `MenuBarState`, `MenuBarMark`, `StatusState`, `NudgeState`, `NudgePhase`, `ActiveBreakState` (`detail`: walk idea; `completion`: the closing moment), `BreakCompletionState`, `AgentChipState`, `RoutineStepState`, `CardState`, `CardContent`, `ResumeCardContent`, `ResumeItem`, `AwayNoteContent`, `ToastContent`, `WindDownCardContent`, `UpdateCardContent`, `UpdateState`, `UpdatePhase`, `UpdateInstallStep` (State/UpdateState.swift), `PopupPriority`, `IntegrationRowState` (`installState`, `canRemove`: outdated and edited installs offer Remove), `TourPresentation` | State/StateTypes.swift |
| `AppActions` (SPEC §7.2 + additions below), `SoundID` | State/AppActions.swift |
| `SurfaceController` | State/SurfaceController.swift |
| Design system: `Theme` (Colors, Tone, TextStep, Typography, Spacing, Radius, Layout, Glass, Backdrop), `Theme.Motion`, `DesignTraits`, `DesignOverrides`, `GlassRendering`, `GlassStage`, `GlassPanelBackground`, `GlassCard`, `GlassCapsule`, `VisualEffectBackground`, `BrandMark`, `BrandMarkShape`, `BrandMarkGlyph`, `PillButton`, `PillButtonStyle`, `Keycap`, `KeyHint`, `KindBadge`, `StatusDot`, `Chip`, `AgentChip`, `Hairline`, `HoverCloseButton`, `ProgressRing`, `RollingNumber`, `SectionHeader`, `SettingsSection`, `SettingsDivider`, `SettingRow`, `SentenceRow`, `SidebarTile`, `PresetCard`, `ToastShell`, `TimeRimTimeline` / `TimeRimSource` (`.timeRim`, `.capsuleTimeRim`) | Design/ |

### `AppActions` additions beyond SPEC §7.2

| Action | Why |
|---|---|
| `ignoreNudge()` | the nudge controller owns the 10 s ignore timer (hover pauses it) and must report `ignored` |
| `cancelAutoStart()` | hover / Not now during eye-rest auto-start (key presses and clicks are detected by the coordinator) |
| `exportHistory()`, `deleteAllData()` | Privacy pane buttons |
| `previewSound(SoundID)` | ▶ on sound rows |
| `completeOnboarding()` | onboarding finished: mark done, login item, then the tour's offer (first time) or the popover once |
| `replayTour()`, `tour(TourInput)` | Settings → General → Take the tour; Next and Skip tour during the tour (SPEC §3.12) |
| `popoverVisibilityChanged(Bool)` | the popover opened or closed: its first-use hint, and the tour's popover step moving on |
| `popoverMayClose(PopoverCloseCause, Bool)` | something that may close the open popover happened (the Bool: the pointer is on it); the coordinator asks `PopoverPolicy` and closes it |
| `checkForUpdates()`, `installUpdate()`, `openUpdate()` | Settings → About Check now; Update (download, verify, swap, reopen) and the download page, on the prompt and in About (SPEC §2.11). Later on the prompt is `dismissCard` |

## Updates (SPEC §2.11)

| Interface | File | Consumed by |
|---|---|---|
| `SemanticVersion`, `UpdateRelease`, `UpdateFeed` (feed URL, parsing), `UpdateRecord` | Models/Updates.swift | App, policy, debug state |
| `UpdatePolicy` (`mayCheck`, `mayPrompt`, `checkIsDue`, `shouldPrompt`, `shouldInstallAutomatically`, …), `UpdateMoment` | Engine/UpdatePolicy.swift | App |
| `UpdateFetching` / `UpdateFetcher` (the only network access) | Kit Services/UpdateFetcher.swift | App |
| `UpdateSignature`, `UpdateKey` (the release key's public half) | Updates/UpdateSignature.swift, Updates/UpdateKey.swift | installer, scripts/update-signing.swift (same signed message) |
| `UpdateInstaller`, `UpdateLocation`, `StagedUpdate`, `SwappedUpdate` | Updates/UpdateInstaller.swift | App |
| `UpdateRelauncher`, `PendingUpdate` | Updates/UpdateRelauncher.swift | App, CLI (`update-relaunch`) |

## The app (Sources/BreakpointApp)

| Piece | File | Notes |
|---|---|---|
| `AppCoordinator` start, wiring, `currentDate()` | AppCoordinator.swift | the socket starts first (hand-over or one alert on failure) |
| Engine loop | AppCoordinator+Loop.swift | cards are never timed here; surfaces own their lifetime |
| `AppActions` | AppCoordinator+Actions.swift | installers run off the main thread; `deleteAllDataNow()` keeps the ledger |
| Core → `AppState` | AppCoordinator+State.swift | |
| Routine and copy rotation (`rotation.json`) | AppCoordinator+Rotation.swift | a real break advances it; a preview changes nothing |
| The step tick, the walk's idea line, the closing moment | AppCoordinator+Pacing.swift | |
| Socket commands (`activate`, `signals`, `debug`) | AppCoordinator+Commands.swift | |
| Update check, prompt, install and reopen | AppCoordinator+Updates.swift | |
| The one-minute tour: sample surfaces, interruptions, `tourStatus` | AppCoordinator+Tour.swift | nothing it shows is recorded or touches the timers, spacing or the breather hold |
| First-use hints: `takeHint`, what the tour taught, the popover's open state | AppCoordinator+Hints.swift | a hint is saved as known the moment it shows |
| End-to-end harness (debug builds only): `DebugHarness`, `SurfaceRecorder`, `SimulatedActivityMonitor`, `RecordingHeadphones`, `RecordingSound` | DebugHarness.swift | driven by `breakpoint debug …` and scripts/e2e.sh |

## Snapshot registry

`Sources/BreakpointSnapshots/SnapshotSupport.swift` defines `Snapshot`, `SnapshotScene`
(`lightAndDark`, `popupBackdrops`, `allBackdrops`, `darkOnly`), `SnapshotVariant`
(`standard`, `reduceTransparency`, `increaseContrast`, `reduceMotion`) and `SnapshotRenderer`
(`.imageRenderer` for pure SwiftUI, `.window` for native controls). Each part appends to its own
`static var all` in `DesignSnapshots.swift` and `GlassSnapshots.swift` (the design system),
`BreakSnapshots.swift`, `MenuBarSnapshots.swift`, `SettingsSnapshots.swift`,
`OnboardingSnapshots.swift`, `TourSnapshots.swift` (`tour/…` and `hints/…`; `TourFilm.swift` draws
the tour in place, frame by frame, then two hints in later real use); `main.swift` concatenates them.
The motion films for review (`MotionFilm.swift`, `OverlayFilm.swift`, `CardRimFilm.swift`,
`ControlsFilm.swift`, sharing `FilmSupport.swift`) stream frames drawn as a pure function of time;
`AppIconRendering.swift` draws the app icon (`--app-icon`) and `WindowProbe.swift` is `--window-probe`.
