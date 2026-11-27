# The packaged Windows app, as a person gets it (CI runs this on every change):
#
#   scripts/windows/smoke.ps1 -Zip build/release/Breakpoint-0.4.0-windows-x64.zip
#
#  1. install.ps1 installs it from a local release folder (size and SHA-256 checked);
#  2. every DLL each executable imports is part of Windows or ships in the zip (the Swift runtime
#     is linked in, the Visual C++ runtime is app-local), so nothing depends on the toolchain;
#  3. with only Windows on PATH and a temporary home: the app starts, answers the CLI over its
#     socket, and quits by itself with exit status 0;
#  4. `breakpoint install claude-code` copies the CLI (with its runtime) to ~\.breakpoint\bin, and
#     the hook command, run by PowerShell as the tools run it, reaches the app;
#  5. `emit` latency over 40 runs (SPEC §5.3: p95 under 50 ms), printed;
#  6. an in-place update's last step for real: the relaunch helper, run from the old copy, starts
#     the new one, which confirms it started.
# Nothing touches the real home folder, the real socket or any tool's real configuration.
param([Parameter(Mandatory)][string]$Zip)
. (Join-Path $PSScriptRoot 'common.ps1')

$Zip = (Resolve-Path $Zip).Path
$version = & (Join-Path $PSScriptRoot 'version.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ("bp-smoke-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $root | Out-Null
$failures = 0
function Pass([string]$what) { Write-Host "  PASS  $what" }
function Fail([string]$what) { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures++ }
function Check([bool]$ok, [string]$what) { if ($ok) { Pass $what } else { Fail $what } }

# 1. The installer, from a folder holding what a release holds.
$release = Join-Path $root 'release'
New-Item -ItemType Directory $release | Out-Null
Copy-Item $Zip $release
$zipItem = Get-Item $Zip
@{ version = $version; notes = 'Smoke test.'; page = "https://github.com/estrindavid/breakpoint/releases/tag/v$version"
   archive = "https://github.com/estrindavid/breakpoint/releases/download/v$version/$($zipItem.Name)"
   size = $zipItem.Length; sha256 = (Get-FileHash -Algorithm SHA256 $Zip).Hash.ToLowerInvariant()
   minimumSystemVersion = '10.0.19041' } | ConvertTo-Json | Set-Content -Encoding utf8NoBOM (Join-Path $release 'update-feed-windows.json')
$programs = Join-Path $root 'Programs'
$env:BREAKPOINT_INSTALL_BASE = $release
$env:BREAKPOINT_INSTALL_DIR = $programs
$env:BREAKPOINT_INSTALL_ALLOW_RUNNING = '1'
$out = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'install.ps1') 2>&1 | Out-String
Remove-Item Env:BREAKPOINT_INSTALL_BASE, Env:BREAKPOINT_INSTALL_DIR, Env:BREAKPOINT_INSTALL_ALLOW_RUNNING
Check ($out -match "Installed Breakpoint $([regex]::Escape($version)) in") "install.ps1 installs and says where"
$app = Join-Path $programs 'Breakpoint'
$exe = Join-Path $app 'Breakpoint.exe'
$cli = Join-Path $app 'bin\breakpoint.exe'
Check ((Test-Path $exe) -and (Test-Path $cli) -and (Test-Path (Join-Path $app 'Breakpoint.ico'))) 'the app, the CLI and the icon are in place'

# 2. What each executable loads.
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath
$dumpbin = Get-ChildItem (Join-Path $vs 'VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe') | Select-Object -Last 1
$system = 'kernel32|user32|gdi32|advapi32|shell32|ole32|oleaut32|ws2_32|bcrypt|shlwapi|dbghelp|userenv|iphlpapi|secur32|winmm|d2d1|dwrite|d3d11|dxgi|dcomp|windowscodecs|dwmapi|shcore|uxtheme|comdlg32|wtsapi32|powrprof|winhttp|imm32|crypt32|version|ntdll|api-ms-win-.*|ucrtbase'
foreach ($file in @($exe, $cli)) {
    $imports = & $dumpbin.FullName /nologo /dependents $file | Where-Object { $_ -match '^\s+\S+\.dll\s*$' } | ForEach-Object { $_.Trim().ToLowerInvariant() }
    $packaged = (Get-ChildItem (Split-Path $file) -Filter *.dll).Name.ToLowerInvariant()
    $unknown = $imports | Where-Object { $_ -notmatch "^($system)\.dll$" -and $packaged -notcontains $_ }
    Check (-not $unknown) "$(Split-Path $file -Leaf) loads only Windows and packaged DLLs$(if ($unknown) { ': not ' + ($unknown -join ', ') })"
}

# 3. Start, answer, quit, with only Windows on PATH.
$savedPath = $env:PATH
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
$home1 = Join-Path $root 'home'
$data = Join-Path $home1 'AppData\Local\Breakpoint'
New-Item -ItemType Directory -Force $data, (Join-Path $home1 '.claude') | Out-Null
'{"version":1,"hasCompletedOnboarding":true}' | Set-Content -Encoding utf8NoBOM (Join-Path $data 'settings.json')
$env:BREAKPOINT_HOME = $home1
try {
    $process = Start-Process -FilePath $exe -ArgumentList '--quit-after', '25' -PassThru
    $answered = $false
    foreach ($i in 1..60) {
        $status = & $cli status 2>$null
        if ($LASTEXITCODE -eq 0 -and $status -match '"appVersion"') { $answered = $true; break }
        Start-Sleep -Milliseconds 250
    }
    Check $answered 'the app starts and answers `breakpoint status`'

    # 4. The CLI copy the hooks call, and a hook run the way the tools run it.
    $out = & $cli install claude-code 2>&1 | Out-String
    $copy = Join-Path $home1 '.breakpoint\bin'
    Check ((Test-Path (Join-Path $copy 'breakpoint.exe')) -and (Test-Path (Join-Path $copy 'vcruntime140.dll')) -and (Test-Path (Join-Path $copy 'msvcp140.dll'))) 'the CLI copy has its runtime with it'
    $settings = Get-Content (Join-Path $home1 '.claude\settings.json') -Raw | ConvertFrom-Json
    $command = ($settings.hooks.UserPromptSubmit.hooks | Where-Object { $_.command -match 'breakpoint' }).command
    Check ($command -match '^[A-Za-z]:/\S+/\.breakpoint/bin/breakpoint\.exe emit agentStarted --source claude-code --stdin-json$') "the hook names the CLI copy by its path: $command"
    '{"session_id":"smoke1","cwd":"C:\\work\\app","prompt":"rename the loader"}' |
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command $command
    Start-Sleep -Milliseconds 500
    $sessions = (& $cli status | ConvertFrom-Json).sessions
    Check ([bool]($sessions | Where-Object { $_.sessionID -eq 'smoke1' -and $_.state -eq 'working' })) 'the installed hook, run by PowerShell, delivers agentStarted'

    # 5. emit latency.
    $times = foreach ($i in 1..40) {
        (Measure-Command { '{"session_id":"lat","prompt":"x"}' | & (Join-Path $copy 'breakpoint.exe') emit agentActivity --source claude-code --stdin-json }).TotalMilliseconds
    }
    $sorted = $times | Sort-Object
    $p50 = [math]::Round($sorted[19]); $p95 = [math]::Round($sorted[37])
    Write-Host "  emit latency over 40 runs: p50 $p50 ms, p95 $p95 ms (SPEC §5.3 target: p95 under 50 ms; includes starting the process from PowerShell)"
    Check ($p95 -lt 250) 'emit stays fast (p95 under 250 ms on this runner)'

    $process.WaitForExit(40000) | Out-Null
    Check ($process.HasExited -and $process.ExitCode -eq 0) "the app quits by itself with exit status 0 (got $(if ($process.HasExited) { $process.ExitCode } else { 'still running' }))"

    # 6. The relaunch helper, run from the old copy, starts the new one, which confirms it started.
    $staging = Join-Path $programs ('.Breakpoint-update-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory $staging | Out-Null
    Copy-Item -Recurse $app (Join-Path $staging 'Breakpoint')
    $dead = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', 'exit' -PassThru -WindowStyle Hidden
    $dead.WaitForExit()
    $toUri = { param($p) ([Uri]((Resolve-Path $p).Path)).AbsoluteUri }
    $pending = [ordered]@{
        fromVersion = '0.0.1'; toVersion = $version
        swapped = [ordered]@{ installed = (& $toUri $app); backup = (& $toUri (Join-Path $staging 'Breakpoint')); stagingDirectory = (& $toUri $staging) }
        startedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $pending | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8NoBOM (Join-Path $data 'pending-update.json')
    $helper = Start-Process -FilePath (Join-Path $staging 'Breakpoint\bin\breakpoint.exe') -ArgumentList 'update-relaunch', '--pid', $dead.Id -PassThru -WindowStyle Hidden
    $helper.WaitForExit(60000) | Out-Null
    Check ($helper.HasExited -and $helper.ExitCode -eq 0) "the relaunch helper sees the new copy confirm (exit $(if ($helper.HasExited) { $helper.ExitCode } else { 'still running' }))"
    Check (-not (Test-Path (Join-Path $data 'pending-update.json'))) 'and clears pending-update.json'
    & $cli status *> $null
    Check ($LASTEXITCODE -eq 0) 'the copy it started is running'
} finally {
    Get-Process -Name Breakpoint -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$programs*" } | Stop-Process -Force
    $env:PATH = $savedPath
    Remove-Item Env:BREAKPOINT_HOME
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures -gt 0) { Write-Host "smoke: $failures failed" -ForegroundColor Red; exit 1 }
Write-Host 'smoke: all passed'
