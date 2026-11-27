import Foundation

/// Where installers read and write. Everything derives from `paths.home`, so tests pass a
/// temporary directory and never touch the real home folder (SPEC §5.5).
public struct IntegrationEnvironment: Sendable {
    public var paths: BreakpointPaths
    /// `Settings.codexHome` override, else `$CODEX_HOME`, else `~/.codex`.
    public var codexHomeOverride: String?
    /// The process environment (for `$CODEX_HOME`). Tests pass an explicit dictionary.
    public var processEnvironment: [String: String]
    public var now: @Sendable () -> Date
    /// The CLI to copy to `~/.breakpoint/bin/breakpoint` on install (the app's bundled copy, or the
    /// running `breakpoint`). When nil, installers leave the CLI copy to the caller.
    public var bundledCLI: URL?

    public init(
        paths: BreakpointPaths,
        codexHomeOverride: String? = nil,
        processEnvironment: [String: String] = [:],
        now: @escaping @Sendable () -> Date = { Date() },
        bundledCLI: URL? = nil
    ) {
        self.paths = paths
        self.codexHomeOverride = codexHomeOverride
        self.processEnvironment = processEnvironment
        self.now = now
        self.bundledCLI = bundledCLI
    }

    public var home: URL { paths.home }

    /// The Codex home folder (SPEC §5.5). `$CODEX_HOME` is ignored while `BREAKPOINT_HOME` is set,
    /// so a development or test home can never reach a real Codex folder.
    public var codexHome: URL {
        if let override = codexHomeOverride, !override.isEmpty {
            return URL(fileURLWithPath: Self.expandTilde(override, home: home.path), isDirectory: true)
        }
        let sandboxed = !(processEnvironment[BreakpointPaths.homeOverrideVariable] ?? "").isEmpty
        if !sandboxed, let env = processEnvironment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: Self.expandTilde(env, home: home.path), isDirectory: true)
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Copies the CLI to `~/.breakpoint/bin/breakpoint` when `bundledCLI` is set and the copy is
    /// missing or from another version (SPEC §5.2).
    func ensureCLICopy() throws {
        guard let bundledCLI else { return }
        let installer = CLIInstaller(paths: paths, bundledCLI: bundledCLI)
        if installer.needsRefresh() { try installer.install() }
    }
}

extension IntegrationEnvironment {
    /// `~` / `~/x` expanded against `home` (not the process's real home).
    static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }
}

/// What an install or uninstall did.
public struct InstallReport: Equatable, Sendable {
    /// Files written or edited.
    public var changedFiles: [URL]
    /// Backups made before editing (in `backups/`).
    public var backups: [URL]
    /// Sentences for the user, e.g. "Open /hooks in Codex and trust the new entries."
    public var notes: [String]

    public init(changedFiles: [URL] = [], backups: [URL] = [], notes: [String] = []) {
        self.changedFiles = changedFiles
        self.backups = backups
        self.notes = notes
    }
}

/// Why an installer refused or failed. `explanation` is one sentence for the UI and CLI.
public enum IntegrationError: Error, Equatable, Sendable {
    /// The tool's folder does not exist.
    case toolNotFound(IntegrationID)
    /// The config file exists but does not parse; nothing was written.
    case unparseableFile(URL, reason: String)
    /// Codex legacy notify: `notify` is already set; Breakpoint never chains it.
    case notifyAlreadySet(URL)
    /// Codex hooks and legacy notify are mutually exclusive.
    case conflictsWith(IntegrationID)
    /// The file changed between read and write; retry.
    case concurrentModification(URL)
    case io(String)

    public var explanation: String {
        switch self {
        case .toolNotFound(let id): return "\(id.displayName) was not found on this Mac."
        case .unparseableFile(let url, let reason): return "\(url.lastPathComponent) could not be read (\(reason)), so nothing was changed."
        case .notifyAlreadySet(let url): return "\(url.lastPathComponent) already sets notify, so Breakpoint left it alone."
        case .conflictsWith(let id): return "Remove the \(id.displayName) integration first."
        case .concurrentModification(let url): return "\(url.lastPathComponent) changed while installing. Try again."
        case .io(let message): return message
        }
    }
}

/// One installable tool (SPEC §5.5, §7.1).
///
/// Contract for every implementation:
/// - Reads and writes only under `environment.home` (user-level files only; never project files).
/// - `detect()`: the tool's folder exists. No writes.
/// - `status()`: `.notFound` / `.notInstalled` / `.installed` / `.outdated` / `.modified` /
///   `.unreadable`, from the file on disk. No writes.
/// - `install()`: writes nothing unless called. Backs up the file to `backups/` first; refuses with
///   `.unparseableFile` if it does not parse; re-reads immediately before writing; appends only
///   Breakpoint's marked entries without touching foreign keys or entries, preserving key order and
///   indentation; writes via a temp file in the same directory and `rename`, keeping the file mode
///   (and following symbolic links); idempotent (an install that is already current writes nothing,
///   an older or edited install is replaced). Ensures the CLI copy exists when
///   `environment.bundledCLI` is set (`CLIInstaller`). Throws `.toolNotFound` if `detect()` is false.
/// - `uninstall()`: removes only marked entries, then empty groups, arrays and `hooks`; deletes a
///   file or folder Breakpoint created once nothing else is in it, and restores a file that was empty
///   before. Uninstalling something not installed changes nothing.
/// - Synchronous; the app calls them off the main thread.
public protocol Integration: Sendable {
    var id: IntegrationID { get }
    var displayName: String { get }
    var environment: IntegrationEnvironment { get }
    /// The file this integration edits or owns.
    var configFile: URL { get }

    func detect() -> Bool
    func status() -> IntegrationInstallState
    func install() throws -> InstallReport
    func uninstall() throws -> InstallReport
}

extension Integration {
    public var displayName: String { id.displayName }
}

/// Builds the integration for each `IntegrationID`.
public enum IntegrationRegistry {
    public static func integration(_ id: IntegrationID, environment: IntegrationEnvironment) -> any Integration {
        switch id {
        case .claudeCode: return ClaudeCodeIntegration(environment: environment)
        case .cursor: return CursorIntegration(environment: environment)
        case .codex: return CodexIntegration(environment: environment)
        case .codexNotify: return CodexNotifyIntegration(environment: environment)
        case .copilot: return CopilotIntegration(environment: environment)
        case .gemini: return GeminiIntegration(environment: environment)
        case .shell: return ShellIntegration(environment: environment)
        }
    }

    public static func all(environment: IntegrationEnvironment) -> [any Integration] {
        IntegrationID.allCases.map { integration($0, environment: environment) }
    }
}

/// What the app verifies after Install, by itself and without waiting for the tool (SPEC §5.6).
///
/// - On disk (`problem(for:state:environment:)`, a few reads; also run whenever the app re-reads
///   install states): the entries read back as current, the CLI copy the hooks call is in place and
///   executable, and the tool has not turned hooks off (`toolProblem`).
/// - End to end (once after each Install): the app runs `hookProcess(for:…)`, the same shell
///   command the hooks run but with kind `test`, the way a tool runs a hook (`/bin/sh -c`, `HOME`
///   set to the home the hooks see, empty stdin). The check passes when that `test` event reaches
///   the app; a `test` event never changes sessions or counts as the tool's own event.
///
/// What this cannot prove is that the tool itself will run the hooks (Codex until its hooks are
/// trusted in /hooks, a shell until a new one starts, a tool that is not running yet).
public enum InstallCheck {
    /// `HookCommand.shell(.test, source:)`: the hook command form, sending a `test` event.
    public static func hookCommand(for id: IntegrationID) -> String {
        HookCommand.shell(.test, source: id.source)
    }

    /// The process that runs `hookCommand(for:)` the way a tool runs a hook. Not started.
    /// `environment` is the app's own; `HOME` is replaced with `paths.home`.
    public static func hookProcess(for id: IntegrationID, paths: BreakpointPaths, environment: [String: String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", hookCommand(for: id)]
        var variables = environment
        variables["HOME"] = paths.home.path
        process.environment = variables
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// What is wrong on disk with an installed integration, as one sentence that says what to do;
    /// nil when nothing is (or when `state` is not `.installed`: the other states say so already).
    public static func problem(for id: IntegrationID, state: IntegrationInstallState,
                               environment: IntegrationEnvironment) -> String? {
        guard state == .installed else { return nil }
        if !FileManager.default.isExecutableFile(atPath: environment.paths.cliCopy.path) {
            return "The command its hooks call is missing from \(binFolder(environment)). Install again to put it back."
        }
        return toolProblem(for: id, environment: environment)
    }

    /// A setting in the tool's own file that keeps it from running any hook: Claude Code's
    /// `"disableAllHooks": true` in `~/.claude/settings.json`.
    public static func toolProblem(for id: IntegrationID, environment: IntegrationEnvironment) -> String? {
        guard id == .claudeCode else { return nil }
        let file = ClaudeCodeIntegration(environment: environment).configFile
        guard let data = try? Data(contentsOf: file),
              let value = try? JValue.parse(String(decoding: data, as: UTF8.self)),
              case .bool(true)? = value["disableAllHooks"] else { return nil }
        return claudeHooksOff
    }

    /// `toolProblem` for Claude Code with `"disableAllHooks": true` in its user settings.
    public static let claudeHooksOff = "Claude Code’s settings have disableAllHooks on. Turn it off, then install again."

    /// The end-to-end check timed out. `cliRuns`: whether the CLI copy itself runs (`cliRuns(…)`).
    public static func unreachableProblem(cliRuns: Bool, environment: IntegrationEnvironment) -> String {
        if !cliRuns {
            return "The command its hooks call, in \(binFolder(environment)), doesn’t run on this Mac. Install again to replace it."
        }
        let doctor = PathDisplay.abbreviatingHome(environment.paths.cliCopy.path, home: environment.home.path)
        return "Its hooks can’t reach Breakpoint. To see why, run \(doctor) doctor."
    }

    /// Runs `<CLI copy> --version` (piped, so it prints "breakpoint <version>" alone) and returns
    /// whether it did so within `timeout`.
    public static func cliRuns(paths: BreakpointPaths, timeout: TimeInterval = 5) -> Bool {
        let process = Process()
        process.executableURL = paths.cliCopy
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return false
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return process.terminationStatus == 0 && text.hasPrefix("breakpoint ")
    }

    private static func binFolder(_ environment: IntegrationEnvironment) -> String {
        PathDisplay.abbreviatingHome(environment.paths.binDirectory.path, home: environment.home.path)
    }
}
