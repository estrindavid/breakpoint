import Foundation
#if os(Windows)
import WinSDK
#endif

/// Shell on Windows (SPEC §5.5): PowerShell. A snippet in `~/.breakpoint/shell/breakpoint.ps1`,
/// dot-sourced from a marker block at the end of each PowerShell's own profile for the current
/// user and host (`$PROFILE`):
///
/// - PowerShell 7: `Documents\PowerShell\Microsoft.PowerShell_profile.ps1`
/// - Windows PowerShell 5.1: `Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`
///
/// `Documents` is the user's Documents known folder (often redirected to OneDrive), or
/// `<home>\Documents` under `BREAKPOINT_HOME`. The 5.1 profile is created if missing (that shell is
/// on every Windows); the 7 profile only when PowerShell 7's folder exists. The block goes at the
/// end of the profile, so a prompt set up earlier (Starship, Oh My Posh) is wrapped, not replaced.
/// Always "found".
public struct PowerShellIntegration: Integration {
    public let environment: IntegrationEnvironment
    public init(environment: IntegrationEnvironment) { self.environment = environment }
    public var id: IntegrationID { .shell }
    public func detect() -> Bool { true }

    public var documents: URL { environment.documentsFolder }
    public var windowsPowerShellProfile: URL {
        documents.appendingPathComponent("WindowsPowerShell/Microsoft.PowerShell_profile.ps1")
    }
    public var powerShellProfile: URL { documents.appendingPathComponent("PowerShell/Microsoft.PowerShell_profile.ps1") }
    public var profiles: [URL] { [powerShellProfile, windowsPowerShellProfile] }
    public var configFile: URL { windowsPowerShellProfile }

    var paths: BreakpointPaths { environment.paths }

    public static let blockBody = """
    # Added by Breakpoint (long-running commands). Remove with: ~/.breakpoint/bin/breakpoint uninstall shell
    if (Test-Path -LiteralPath "$HOME\\.breakpoint\\shell\\breakpoint.ps1") { . "$HOME\\.breakpoint\\shell\\breakpoint.ps1" }
    """

    private func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The profiles install edits: the 5.1 one always, the 7 one when that PowerShell has a folder.
    private var wantedProfiles: [URL] {
        (isFolder(powerShellProfile.deletingLastPathComponent()) ? [powerShellProfile] : []) + [windowsPowerShellProfile]
    }

    private func config(_ url: URL) -> ConfigFile { ConfigFile(url: url, tool: id, environment: environment) }

    private func malformed(_ url: URL) -> IntegrationError {
        .unparseableFile(url, reason: "it has a Breakpoint block with a missing marker line")
    }

    private func readOwned(_ url: URL) -> String? {
        (try? SafeFile.read(url)).map { String(decoding: $0, as: UTF8.self) }
    }

    public func status() -> IntegrationInstallState {
        do {
            var present = false
            var complete = true
            let wanted = wantedProfiles
            for url in profiles {
                let text = try config(url).read() ?? ""
                let body: String?
                do {
                    body = try MarkerBlockEditor.body(in: text)
                } catch {
                    return .unreadable(reason: "\(url.lastPathComponent) has a Breakpoint block with a missing marker line.")
                }
                if let body {
                    present = true
                    if body != Self.blockBody { return .modified }
                } else if wanted.contains(url) {
                    complete = false
                }
            }
            guard present else { return .notInstalled }
            if readOwned(paths.shellPowerShellSnippet) != PowerShellSnippet.text { complete = false }
            return complete ? .installed : .outdated
        } catch let error as IntegrationError {
            return .unreadable(reason: error.statusSentence)
        } catch {
            return .unreadable(reason: "A PowerShell profile could not be read.")
        }
    }

    public func install() throws -> InstallReport {
        let wanted = wantedProfiles
        for url in wanted {
            if let text = try config(url).read() {
                guard (try? MarkerBlockEditor.ranges(in: text)) != nil else { throw malformed(url) }
            }
        }
        try environment.ensureCLICopy()

        var report = InstallReport()
        do {
            try FileManager.default.createDirectory(at: paths.shellDirectory, withIntermediateDirectories: true)
            if readOwned(paths.shellPowerShellSnippet) != PowerShellSnippet.text {
                try AtomicFile.write(Data(PowerShellSnippet.text.utf8), to: paths.shellPowerShellSnippet, mode: 0o644)
                report.changedFiles.append(paths.shellPowerShellSnippet)
            }
        } catch let error as IntegrationError {
            throw error
        } catch {
            throw IntegrationError.io("Could not write the PowerShell snippet in \(paths.shellDirectory.path).")
        }

        for url in wanted {
            try CreatedDirectory.ensure(url.deletingLastPathComponent(), environment: environment)
            let file = config(url)
            var original: String?
            let change = try file.update { text in
                original = text
                do {
                    return try MarkerBlockEditor.upsertChecked(body: Self.blockBody, in: text ?? "")
                } catch {
                    throw malformed(url)
                }
            }
            if let change {
                if original?.isBlank ?? true { file.remember(original: original) }
                report.changedFiles.append(change.file)
                if let backup = change.backup { report.backups.append(backup) }
            }
        }

        report.notes.append("Open a new PowerShell window to start.")
        report.notes.append("PowerShell runs your profile only when its execution policy allows local scripts (RemoteSigned, the PowerShell 7 default).")
        return report
    }

    public func uninstall() throws -> InstallReport {
        var report = InstallReport()
        for url in profiles {
            let file = config(url)
            let record = file.ledgerRecord()
            let change = try file.update { text in
                guard let text else { return nil }
                let removed: String
                do {
                    removed = try MarkerBlockEditor.removeChecked(from: text)
                } catch {
                    throw malformed(url)
                }
                guard removed != text else { return text }
                if let record, record.hasOriginal, removed.isBlank { return record.original }
                return removed
            }
            if record != nil { file.forgetRecord() }
            if let change {
                report.changedFiles.append(change.file)
                if let backup = change.backup { report.backups.append(backup) }
            }
            CreatedDirectory.removeIfEmpty(url.deletingLastPathComponent(), environment: environment)
        }
        if fileExists(paths.shellPowerShellSnippet) {
            try? FileManager.default.removeItem(at: paths.shellPowerShellSnippet)
            report.changedFiles.append(paths.shellPowerShellSnippet)
        }
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: paths.shellDirectory.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: paths.shellDirectory)
        }
        return report
    }
}

extension IntegrationEnvironment {
    /// The Documents folder PowerShell keeps its profiles in: `$BREAKPOINT_DOCUMENTS` when set;
    /// `<home>/Documents` for any home other than the real one (development and tests); otherwise
    /// the user's Documents known folder (which OneDrive may have moved).
    public var documentsFolder: URL {
        if let override = processEnvironment["BREAKPOINT_DOCUMENTS"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let fallback = home.appendingPathComponent("Documents", isDirectory: true)
        #if os(Windows)
        guard home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL,
              processEnvironment[BreakpointPaths.homeOverrideVariable] == nil else { return fallback }
        var known = FOLDERID_Documents
        var pointer: PWSTR?
        guard SHGetKnownFolderPath(&known, 0, nil, &pointer) == S_OK, let pointer else { return fallback }
        defer { CoTaskMemFree(pointer) }
        return URL(fileURLWithPath: String(decodingCString: pointer, as: UTF16.self), isDirectory: true)
        #else
        return fallback
        #endif
    }
}

/// The PowerShell snippet (Windows PowerShell 5.1 and PowerShell 7). Like the zsh and bash
/// snippets it sends only each command's name (the first command token, from PowerShell's own
/// tokenizer, so a quoted argument or a `$env:X = …` value never leaks), only in an interactive
/// console, at most once per session, with `--session` the shell's process ID, the finish only for
/// commands of 2 s or more, and the CLI started in the background with no window. It keeps `$?`
/// and `$LASTEXITCODE` for the prompt it wraps.
///
/// Start: `PSConsoleHostReadLine` (PSReadLine) is wrapped, so the line is known when Enter is
/// pressed. Finish: `prompt` is wrapped and reads the last history entry's times and the status.
public enum PowerShellSnippet {
    public static let header = "# Breakpoint shell integration (generated by Breakpoint; reinstalling replaces this file).\n"
        + "# Sends the name of each command you run (its first word only) to the Breakpoint app.\n"

    public static let text = header + #"""
    if ($global:__bp_loaded -or $Host.Name -ne 'ConsoleHost') { return }
    if ([Environment]::GetCommandLineArgs() -match '^-(c|command|f|file|e|ec|encodedcommand|noni|noninteractive)$') { return }
    $global:__bp_loaded = $true
    $global:__bp = @{
        Bin = Join-Path $HOME '.breakpoint\bin\breakpoint.exe'
        Prompt = $function:prompt
        ReadLine = $null
        Name = ''
        Hist = -1
    }

    function global:__bp_command_name([string]$line) {
        if ($line.Length -gt 512) { $line = $line.Substring(0, 512) }
        $errors = $null
        $tokens = [System.Management.Automation.PSParser]::Tokenize($line, [ref]$errors)
        $wrapped = $false
        foreach ($token in $tokens) {
            if ($token.Type -eq 'Command' -or ($wrapped -and $token.Type -eq 'CommandArgument')) {
                $name = $token.Content
                if ($name -in @('sudo', 'time', 'env', 'nohup', 'Measure-Command')) { $wrapped = $true; continue }
                return $name
            }
        }
        return ''
    }

    function global:__bp_quote([string]$s) {
        '"' + (($s -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
    }

    function global:__bp_emit([string[]]$arguments) {
        if (-not (Test-Path -LiteralPath $global:__bp.Bin)) { return }
        try {
            $info = New-Object System.Diagnostics.ProcessStartInfo
            $info.FileName = $global:__bp.Bin
            $info.Arguments = ($arguments | ForEach-Object { __bp_quote $_ }) -join ' '
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $process = [System.Diagnostics.Process]::Start($info)
            if ($process) { $process.Dispose() }
        } catch {}
    }

    if (Get-Command PSConsoleHostReadLine -ErrorAction Ignore) {
        $global:__bp.ReadLine = $function:PSConsoleHostReadLine
        function global:PSConsoleHostReadLine {
            $line = & $global:__bp.ReadLine
            $global:__bp.Name = __bp_command_name "$line"
            if ($global:__bp.Name) {
                __bp_emit @('emit', 'commandStarted', '--source', 'shell', '--session', "$PID", '--cwd', "$PWD", '--title', $global:__bp.Name)
            }
            $line
        }
    }

    function global:prompt {
        $ok = $global:?
        $code = $global:LASTEXITCODE
        $last = Get-History -Count 1 -ErrorAction Ignore
        if ($last -and $last.Id -ne $global:__bp.Hist) {
            $global:__bp.Hist = $last.Id
            $name = $global:__bp.Name
            if (-not $global:__bp.ReadLine) { $name = __bp_command_name $last.CommandLine }
            $ms = [int64]($last.EndExecutionTime - $last.StartExecutionTime).TotalMilliseconds
            if ($name -and $ms -ge 2000) {
                $status = if ($ok) { 0 } elseif ($code) { $code } else { 1 }
                __bp_emit @('emit', 'commandFinished', '--source', 'shell', '--session', "$PID", '--cwd', "$PWD", '--title', $name,
                    '--duration-ms', "$ms", '--exit-code', "$status")
            }
        }
        $global:__bp.Name = ''
        $global:LASTEXITCODE = $code
        if (-not $ok) { Write-Error '' -ErrorAction Ignore }
        if ($global:__bp.Prompt) { & $global:__bp.Prompt } else { "PS $($executionContext.SessionState.Path.CurrentLocation)> " }
    }

    """#
}
