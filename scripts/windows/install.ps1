# Installs (or updates) Breakpoint for Windows from its latest GitHub release:
#
#   irm https://github.com/estrindavid/breakpoint/releases/latest/download/install.ps1 | iex
#
# What it does, and nothing else:
#   1. downloads update-feed-windows.json and Breakpoint-<version>-windows-x64.zip from the latest
#      release (HTTPS);
#   2. checks the zip's size and SHA-256 against the feed, that it holds Breakpoint (identifier and
#      version in breakpoint-app.json), and that this is 64-bit Windows 10 2004 or later;
#   3. puts it in %LOCALAPPDATA%\Programs\Breakpoint (per user: no administrator, no UAC prompt),
#      replacing an older copy (settings and history live in %LOCALAPPDATA%\Breakpoint and stay),
#      and adds Breakpoint to the Start menu;
#   4. prints what it did. It does not open the app, change any setting, or ask for a password.
#
# For testing only: BREAKPOINT_INSTALL_BASE (where the release files are, a folder or https URL),
# BREAKPOINT_INSTALL_DIR (the folder to install into; no Start menu entry then),
# BREAKPOINT_INSTALL_ALLOW_RUNNING=1.
#
# Everything is one script block run at the end: PowerShell parses all of it before running any of
# it, so a download cut short runs nothing at all. It never calls `exit` (under `iex` that would
# close the PowerShell window it runs in); a failure is reported, leaves everything as it was, and
# sets $global:LASTEXITCODE to 1.
& {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version 3.0
    $ProgressPreference = 'SilentlyContinue'

    $base = if ($env:BREAKPOINT_INSTALL_BASE) { $env:BREAKPOINT_INSTALL_BASE } else { 'https://github.com/estrindavid/breakpoint/releases/latest/download' }
    $bundleId = 'com.breakpointapp.Breakpoint'
    function Stop-Install([string]$why) { throw [InvalidOperationException]::new($why) }

    $os = [Environment]::OSVersion.Version

    function Get-File([string]$name, [string]$to) {
        if ($base -match '^https://') {
            Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile $to -Headers @{ 'User-Agent' = 'Breakpoint installer' }
        } else {
            Copy-Item (Join-Path ($base -replace '^file:///', '') $name) $to
        }
    }

    $work = Join-Path ([IO.Path]::GetTempPath()) ("breakpoint-install-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory $work | Out-Null
    $target = $null
    $previous = Join-Path $work 'previous'
    try {
        if (-not [Environment]::Is64BitOperatingSystem) { Stop-Install 'Breakpoint needs 64-bit Windows.' }
        if ($env:BREAKPOINT_INSTALL_ALLOW_RUNNING -ne '1' -and (Get-Process -Name Breakpoint -ErrorAction SilentlyContinue)) {
            Stop-Install 'Breakpoint is running. Quit it first (tray icon → right-click → Quit), then run this again.'
        }
        Write-Host 'Fetching the latest release…'
        $feedFile = Join-Path $work 'feed.json'
        Get-File 'update-feed-windows.json' $feedFile
        $feed = Get-Content $feedFile -Raw | ConvertFrom-Json
        $version = [string]$feed.version
        if ($version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') { Stop-Install 'the release information names no version.' }
        $minimum = [string]$feed.minimumSystemVersion
        if ($minimum -notmatch '^\d+(\.\d+){0,2}$') { Stop-Install 'the release information names no Windows version.' }
        if ($os -lt [Version]($minimum + ('.0' * (3 - ($minimum.Split('.').Count))))) {
            Stop-Install "Breakpoint $version needs Windows $minimum or later (this PC has $($os.ToString(3)))."
        }
        $archiveName = [IO.Path]::GetFileName(([Uri]$feed.archive).AbsolutePath)
        if ($archiveName -notmatch '^Breakpoint-[0-9A-Za-z.-]+-windows-x64\.zip$') { Stop-Install 'the release information names an unexpected file.' }

        Write-Host "Downloading Breakpoint $version…"
        $zip = Join-Path $work $archiveName
        Get-File $archiveName $zip
        if ((Get-Item $zip).Length -ne [long]$feed.size) { Stop-Install 'the download has the wrong size.' }
        if ((Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant() -ne ([string]$feed.sha256).ToLowerInvariant()) {
            Stop-Install 'the download does not match its checksum.'
        }
        $unpacked = Join-Path $work 'unpacked'
        Expand-Archive -Path $zip -DestinationPath $unpacked
        $app = Join-Path $unpacked 'Breakpoint'
        $manifest = Get-Content (Join-Path $app 'breakpoint-app.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
        if (-not $manifest -or $manifest.identifier -ne $bundleId -or $manifest.version -ne $version -or
            -not (Test-Path (Join-Path $app 'Breakpoint.exe')) -or -not (Test-Path (Join-Path $app 'bin\breakpoint.exe'))) {
            Stop-Install 'the download does not contain Breakpoint.'
        }
        # Downloaded through PowerShell, the files may carry the "from the internet" mark; this
        # copy was checked against the release above.
        Get-ChildItem -Recurse -File $app | Unblock-File

        $dest = if ($env:BREAKPOINT_INSTALL_DIR) { $env:BREAKPOINT_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs' }
        New-Item -ItemType Directory -Force $dest | Out-Null
        $target = Join-Path $dest 'Breakpoint'
        $before = $null
        if (Test-Path $target) {
            $old = Get-Content (Join-Path $target 'breakpoint-app.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
            $before = if ($old) { $old.version } else { 'an earlier version' }
            Move-Item $target $previous
        }
        Move-Item $app $target

        if (-not $env:BREAKPOINT_INSTALL_DIR) {
            $programs = [Environment]::GetFolderPath('Programs')
            $shell = New-Object -ComObject WScript.Shell
            $link = $shell.CreateShortcut((Join-Path $programs 'Breakpoint.lnk'))
            $link.TargetPath = Join-Path $target 'Breakpoint.exe'
            $link.WorkingDirectory = $target
            $link.IconLocation = (Join-Path $target 'Breakpoint.ico') + ',0'
            $link.Description = 'Break reminders that wait for your agent'
            $link.Save()
        }
        Remove-Item -Recurse -Force $previous -ErrorAction SilentlyContinue

        Write-Host ''
        if ($before -eq $version) { Write-Host "Reinstalled Breakpoint $version in $target." }
        elseif ($before) { Write-Host "Updated Breakpoint $before → $version in $target." }
        else { Write-Host "Installed Breakpoint $version in $target." }
        Write-Host 'Checked: size and SHA-256 match the release. Nothing was opened or changed besides that folder and its Start menu entry.'
        Write-Host 'Open it from the Start menu; it lives in the notification area (the tray).'
        $global:LASTEXITCODE = 0
    } catch {
        # Anything that stops the swap halfway puts the old copy back.
        if ($target -and (Test-Path $previous) -and -not (Test-Path $target)) { Move-Item $previous $target -ErrorAction SilentlyContinue }
        Write-Host "Breakpoint was not installed: $($_.Exception.Message)" -ForegroundColor Red
        $global:LASTEXITCODE = 1
    } finally {
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }
}
