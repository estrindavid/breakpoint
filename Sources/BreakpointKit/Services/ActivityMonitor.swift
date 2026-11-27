import AppKit
import CoreAudio
import CoreGraphics
import CoreMediaIO
import IOKit.pwr_mgt
import BreakpointCore
import BreakpointRuntime

// Reads only the SPEC §2.4 signals, all without a permission prompt.
// Forbidden here and everywhere: NSEvent global monitors for key events, CGEventTap, the
// Accessibility API, window lists or titles, ScreenCaptureKit, INFocusStatusCenter, EventKit,
// UNUserNotificationCenter. Nothing here reads which app is frontmost, which app uses the
// microphone or camera, or any content: only timings, counts and on/off states.

// `ActivityMonitoring` is declared in BreakpointRuntime (Platform/PlatformServices.swift).

/// The live monitor.
///
/// **Microphone in use** is decided per audio device from its shape and state only (never its
/// name, never which app uses it), because CoreAudio's "running somewhere" says nothing about the
/// direction of the IO (verified: output-only speakers report it while playing):
/// 1. Input streams, no output streams (built-in microphone, a stand-alone USB or XLR
///    microphone): in use when running somewhere.
/// 2. Bluetooth with input and output (AirPods, wireless headsets): in use only when running in
///    call mode, detected by a nominal sample rate of 24 kHz or below; playing music runs at
///    44.1 or 48 kHz and does not count.
/// 3. Any other device with input and output (USB headsets, audio interfaces, aggregate devices):
///    never counted, because playback and capture cannot be told apart.
///
/// Known limitation, by design: an audio-only call on a case-3 device is missed (only the camera
/// signal and the manual pause cover it), and case 2 relies on the headset's switch to a
/// telephone-band rate (not verified on real headsets yet; `diagnosticReport()` shows what each
/// device reads as, without names, for checking on a real headset).
///
/// Call signals are kept current by listeners (devices added or removed, running state, nominal
/// sample rate, stream configuration); `sample()` also re-reads them every few seconds (silently:
/// the tick that called it reads `callSignals` next) in case a device does not notify.
@MainActor
public final class ActivityMonitor: ActivityMonitoring {
    public var onCallSignalsChange: ((CallSignals) -> Void)?
    public var onPresenceEvent: ((PresenceEvent) -> Void)?
    public private(set) var callSignals: CallSignals = []

    private var started = false
    private var workspaceTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private let audio = AudioDeviceWatcher()
    /// Presence state as last reported by the system notifications (for the diagnostic report).
    private var locked = false
    private var displaysAsleep = false
    private var screensaverRunning = false
    private var sessionActive = true
    private let video = VideoDeviceWatcher()

    /// `IOPMCopyAssertionsStatus` is an IPC call: read it (and display mirroring) at most every 2 s.
    private var assertionCheckedAt: Date?
    private var displaySleepPrevented = false
    private var displayMirrored = false
    private static let assertionInterval: TimeInterval = 2
    /// Fallback re-read of the call signals.
    private var callSignalsCheckedAt: Date?
    private static let callSignalsInterval: TimeInterval = 5

    public init() {}

    // MARK: Sampling

    public func sample() -> InputSample {
        let now = Date()
        if assertionCheckedAt.map({ now.timeIntervalSince($0) >= Self.assertionInterval }) ?? true {
            assertionCheckedAt = now
            displaySleepPrevented = Self.displaySleepAssertionHeld()
            displayMirrored = Self.anyDisplayMirrored()
        }
        if started, callSignalsCheckedAt.map({ now.timeIntervalSince($0) >= Self.callSignalsInterval }) ?? true {
            callSignalsCheckedAt = now
            callSignals = readCallSignals()
        }
        return InputSample(
            takenAt: now,
            secondsSinceKey: Self.secondsSince(.keyDown),
            secondsSinceAnyInput: Self.secondsSince(Self.anyInput),
            secondsSinceDrag: min(Self.secondsSince(.leftMouseDown), Self.secondsSince(.leftMouseDragged)),
            mouseButtonDown: NSEvent.pressedMouseButtons != 0,
            displaySleepPrevented: displaySleepPrevented,
            secondsSinceScroll: Self.secondsSince(.scrollWheel),
            displayMirrored: displayMirrored)
    }

    /// `kCGAnyInputEventType` (~0).
    private static let anyInput = CGEventType(rawValue: ~0)!

    /// Seconds since the last event of `type` in the login session (HID idle time; no permission).
    private static func secondsSince(_ type: CGEventType) -> TimeInterval {
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
        return seconds.isFinite ? max(0, seconds) : .greatestFiniteMagnitude
    }

    /// Whether some process holds an assertion that keeps the display awake (video, slides).
    /// Reads counts only, never which process holds them.
    static func displaySleepAssertionHeld() -> Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let counts = status?.takeRetainedValue() as? [String: Any] else { return false }
        // kIOPMAssertionTypePreventUserIdleDisplaySleep and the older kIOPMAssertionTypeNoDisplaySleep.
        let keys = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
        return keys.contains { ((counts[$0] as? NSNumber)?.intValue ?? 0) > 0 }
    }

    /// Whether any active display is in a mirror set (a projector or TV showing the same
    /// picture). Display configuration only (Quartz Display Services): no screen content, no
    /// window list, no permission.
    static func anyDisplayMirrored() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsInMirrorSet($0) != 0 }
    }

    // MARK: Lifecycle

    public func start() {
        guard !started else { return }
        started = true

        audio.onChange = { [weak self] in self?.callSignalsMayHaveChanged() }
        video.onChange = { [weak self] in self?.callSignalsMayHaveChanged() }
        audio.start()
        video.start()
        callSignals = readCallSignals()
        callSignalsCheckedAt = Date()

        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceEvents: [(Notification.Name, PresenceEvent)] = [
            (NSWorkspace.screensDidSleepNotification, .displaysSlept),
            (NSWorkspace.screensDidWakeNotification, .displaysWoke),
            (NSWorkspace.willSleepNotification, .systemWillSleep),
            (NSWorkspace.didWakeNotification, .systemDidWake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActivated),
        ]
        for (name, event) in workspaceEvents {
            workspaceTokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.post(event) }
            })
        }

        let distributed = DistributedNotificationCenter.default()
        let distributedEvents: [(String, PresenceEvent)] = [
            ("com.apple.screenIsLocked", .locked),
            ("com.apple.screenIsUnlocked", .unlocked),
            ("com.apple.screensaver.didstart", .screensaverStarted),
            ("com.apple.screensaver.didstop", .screensaverStopped),
        ]
        for (name, event) in distributedEvents {
            distributedTokens.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.post(event) }
            })
        }
    }

    public func stop() {
        guard started else { return }
        started = false
        audio.stop()
        video.stop()
        audio.onChange = nil
        video.onChange = nil
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributedTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        workspaceTokens = []
        distributedTokens = []
    }

    private func post(_ event: PresenceEvent) {
        switch event {
        case .locked: locked = true
        case .unlocked: locked = false
        case .displaysSlept: displaysAsleep = true
        case .displaysWoke: displaysAsleep = false
        case .screensaverStarted: screensaverRunning = true
        case .screensaverStopped: screensaverRunning = false
        case .sessionResigned: sessionActive = false
        case .sessionActivated: sessionActive = true
        case .systemWillSleep, .systemDidWake: break
        }
        onPresenceEvent?(event)
    }

    // MARK: Call signals

    private func readCallSignals() -> CallSignals {
        var signals: CallSignals = []
        if MicrophoneUse.isInUse(AudioDeviceWatcher.devices()) { signals.insert(.microphone) }
        if video.anyRunning() { signals.insert(.camera) }
        return signals
    }

    // MARK: Diagnostics

    /// A plain-text report of every signal this monitor reads and the decision reached: idle
    /// times, mouse button, display-sleep assertion, lock / display / screensaver / session state,
    /// one generic line per audio device ("Bluetooth, input+output, running, 16 kHz → counted as
    /// call"), and camera state. No device names, identifiers or app names. Reads fresh values;
    /// works whether or not `start()` was called (lock and sleep state need `start()`).
    public func diagnosticReport() -> String {
        let now = Date()
        assertionCheckedAt = nil
        let sample = sample()
        return ActivityDiagnostics.report(
            sample: sample, audioDevices: AudioDeviceWatcher.devices(), cameraInUse: video.anyRunning(),
            locked: locked, displaysAsleep: displaysAsleep, screensaverRunning: screensaverRunning,
            sessionActive: sessionActive, at: now)
    }

    private func callSignalsMayHaveChanged() {
        let signals = readCallSignals()
        callSignalsCheckedAt = Date()
        guard signals != callSignals else { return }
        callSignals = signals
        onCallSignalsChange?(signals)
    }
}

// MARK: - CoreAudio: the shape and state of every audio device

/// Reads each audio device's transport type, stream directions, running state and nominal sample
/// rate (`AudioDeviceState`), and listens for changes that can flip the microphone decision:
/// devices added or removed, running state, nominal sample rate and stream configuration. Never
/// reads names or identifiers beyond the transient object ids, and never opens a device.
@MainActor
final class AudioDeviceWatcher {
    var onChange: (() -> Void)?
    private var deviceListeners: [AudioObjectID: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]] = [:]
    private var listListener: AudioObjectPropertyListenerBlock?

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// The per-device properties whose changes can flip the decision.
    private static var watchedProperties: [AudioObjectPropertyAddress] {
        [address(kAudioDevicePropertyDeviceIsRunningSomewhere),
         address(kAudioDevicePropertyNominalSampleRate),
         address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput),
         address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)]
    }

    func start() {
        guard listListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.watchDevices()
                self?.onChange?()
            }
        }
        var list = Self.address(kAudioHardwarePropertyDevices)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &list, .main, block) == noErr {
            listListener = block
        }
        watchDevices()
    }

    func stop() {
        if let block = listListener {
            var list = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &list, .main, block)
        }
        listListener = nil
        for id in Array(deviceListeners.keys) { unwatch(id) }
    }

    private func watchDevices() {
        let current = Set(Self.deviceIDs())
        for id in Array(deviceListeners.keys) where !current.contains(id) { unwatch(id) }
        for id in current where deviceListeners[id] == nil {
            var installed: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
            for property in Self.watchedProperties {
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.onChange?() }
                }
                var address = property
                if AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr {
                    installed.append((property, block))
                }
            }
            deviceListeners[id] = installed
        }
    }

    private func unwatch(_ id: AudioObjectID) {
        for (property, block) in deviceListeners[id] ?? [] {
            var address = property
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        deviceListeners[id] = nil
    }

    // MARK: Reading

    /// Every audio device's state. A device that disappears between listing and reading is left
    /// out.
    static func devices() -> [AudioDeviceState] {
        deviceIDs().compactMap(state)
    }

    static func deviceIDs() -> [AudioObjectID] {
        var list = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &list, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func state(_ id: AudioObjectID) -> AudioDeviceState? {
        guard let transportCode = uint32(id, kAudioDevicePropertyTransportType),
              let running = uint32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) else { return nil }
        var rateAddress = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        let rateRead = AudioObjectGetPropertyData(id, &rateAddress, 0, nil, &rateSize, &rate) == noErr
        return AudioDeviceState(transport: transport(transportCode),
                                hasInput: hasStreams(id, kAudioObjectPropertyScopeInput),
                                hasOutput: hasStreams(id, kAudioObjectPropertyScopeOutput),
                                runningSomewhere: running != 0,
                                nominalSampleRate: rateRead && rate > 0 ? rate : nil)
    }

    static func transport(_ code: UInt32) -> AudioDeviceState.Transport {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return .aggregate
        case kAudioDeviceTransportTypeVirtual: return .virtual
        default: return .other
        }
    }

    private static func hasStreams(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
        var streams = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr && size > 0
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var property = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr ? value : nil
    }
}

// MARK: - CoreMediaIO: is any camera running somewhere?

/// Watches every video device. Reads on/off only; never opens a device or a stream.
@MainActor
final class VideoDeviceWatcher {
    var onChange: (() -> Void)?
    private var deviceListeners: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private var listListener: CMIOObjectPropertyListenerBlock?

    private static var devicesAddress: CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }
    private static var runningAddress: CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    func start() {
        guard listListener == nil else { return }
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.watchDevices()
                self?.onChange?()
            }
        }
        var address = Self.devicesAddress
        if CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, .main, block) == noErr {
            listListener = block
        }
        watchDevices()
    }

    func stop() {
        if let block = listListener {
            var address = Self.devicesAddress
            CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, .main, block)
        }
        listListener = nil
        for (id, block) in deviceListeners {
            var address = Self.runningAddress
            CMIOObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        deviceListeners = [:]
    }

    func anyRunning() -> Bool {
        Self.devices().contains(where: Self.isRunningSomewhere)
    }

    private func watchDevices() {
        let current = Set(Self.devices())
        for (id, block) in deviceListeners where !current.contains(id) {
            var address = Self.runningAddress
            CMIOObjectRemovePropertyListenerBlock(id, &address, .main, block)
            deviceListeners[id] = nil
        }
        for id in current where deviceListeners[id] == nil {
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
            var address = Self.runningAddress
            if CMIOObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr {
                deviceListeners[id] = block
            }
        }
    }

    static func devices() -> [CMIOObjectID] {
        var address = devicesAddress
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    static func isRunningSomewhere(_ id: CMIOObjectID) -> Bool {
        var address = runningAddress
        var value: UInt32 = 0
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr
            && value != 0
    }
}
