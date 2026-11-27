import BreakpointCore
import BreakpointRuntime
import CBreakpointWin32
import Foundation
import WinSDK

// The smaller Windows services behind the runtime's protocols.

// MARK: - Sound

/// The cues of SPEC §4.7, synthesised by the shared `ChimeSynth` (identical to macOS) and played
/// from memory with `PlaySound`, asynchronously. The audio device is used only while a cue
/// sounds. Output only.
@MainActor
public final class WindowsSoundPlayer: SoundPlaying {
    private var samples: [SoundID: [Float]] = [:]
    /// The WAV being played: `PlaySound` reads it until the cue ends.
    private var playing: [UInt8] = []

    public init() {}

    public func play(_ sound: SoundID, volume: Double) {
        let level = Float(min(max(volume, 0), 1))
        guard level > 0 else { return }
        let source = samples[sound] ?? ChimeSynth.samples(for: sound)
        samples[sound] = source
        let wave = Self.wav(source, level: level)
        _ = PlaySoundW(nil, nil, 0) // stop the previous cue before its buffer is replaced
        playing = wave
        playing.withUnsafeBufferPointer { buffer in
            _ = buffer.baseAddress.map {
                PlaySoundW(UnsafeRawPointer($0).assumingMemoryBound(to: WCHAR.self), nil,
                           DWORD(SND_MEMORY | SND_ASYNC | SND_NODEFAULT))
            }
        }
    }

    /// 16-bit mono PCM in a RIFF container.
    static func wav(_ samples: [Float], level: Float) -> [UInt8] {
        var data = [UInt8]()
        data.reserveCapacity(44 + samples.count * 2)
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(ChimeSynth.sampleRate)
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(1); put32(rate); put32(rate * 2); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put32(bytes)
        for sample in samples {
            let value = Int16(max(-1, min(1, sample * level)) * Float(Int16.max))
            put16(UInt16(bitPattern: value))
        }
        return data
    }
}

// MARK: - Open at login

/// "Open at login": the per-user Run key (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`,
/// value `Breakpoint`), which Settings → Apps → Startup lists and can turn off. Registers only an
/// installed copy (`LoginItemAvailability`), never a development build.
@MainActor
public final class WindowsLoginItem: LoginItemControlling {
    static let runKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
    static let valueName = "Breakpoint"

    public init() {}

    public func availability() -> LoginItemAvailability {
        let install = Self.executable.deletingLastPathComponent()
        let isApp = AppBundle.isApp(install) && FileManager.default.fileExists(atPath: install.appendingPathComponent(AppBundle.manifestName).path)
        return LoginItemAvailability.evaluate(bundlePath: install.path, isAppBundle: isApp,
                                              environment: ProcessInfo.processInfo.environment)
    }

    public var isEnabled: Bool {
        var size: DWORD = 0
        return RegGetValueW(HKEY_CURRENT_USER, Self.runKey.wide, Self.valueName.wide, DWORD(RRF_RT_REG_SZ), nil, nil, &size)
            == ERROR_SUCCESS
    }

    public func setEnabled(_ enabled: Bool) throws {
        let availability = availability()
        if enabled {
            guard availability.allowsRegistering else { return }
            let command = "\"" + PathDisplay.native(Self.executable) + "\""
            let value = command.wide
            let status = value.withUnsafeBufferPointer { buffer in
                RegSetKeyValueW(HKEY_CURRENT_USER, Self.runKey.wide, Self.valueName.wide, DWORD(REG_SZ),
                                buffer.baseAddress, DWORD(buffer.count * MemoryLayout<WCHAR>.size))
            }
            guard status == ERROR_SUCCESS else { throw LoginItemError.registry(Int32(status)) }
        } else {
            guard availability.allowsUnregistering else { return }
            let status = RegDeleteKeyValueW(HKEY_CURRENT_USER, Self.runKey.wide, Self.valueName.wide)
            guard status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND else { throw LoginItemError.registry(Int32(status)) }
        }
    }

    static var executable: URL {
        var buffer = [WCHAR](repeating: 0, count: 32_768)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        return URL(fileURLWithPath: String(decoding: buffer.prefix(Int(length)), as: UTF16.self))
    }

    enum LoginItemError: Error, CustomStringConvertible {
        case registry(Int32)
        var description: String {
            switch self {
            case .registry(let code): return "Windows could not change the startup list (\(SystemErrorText.describe(code)))."
            }
        }
    }
}

// MARK: - AirPods

/// The AirPods movement check needs Core Motion, which Windows does not have: never available,
/// and the setting is hidden (SPEC §2.9).
@MainActor
public final class UnavailableHeadphoneMotion: HeadphoneMotionMonitoring {
    public init() {}
    public var isAvailable: Bool { false }
    public func prepare(enabled: Bool) {}
    public func begin() {}
    public func end() -> Bool { false }
}
