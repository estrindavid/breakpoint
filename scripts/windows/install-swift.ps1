# Installs the Swift toolchain for Windows on a CI runner (used by .github/workflows/ci.yml and
# release.yml):
#
#   scripts/windows/install-swift.ps1
#
# Downloads swift.org's installer for the pinned version, checks its SHA-256 and that Apple signed it
# (Authenticode) before running it, installs it silently, and passes the toolchain's PATH entries and
# variables (SDKROOT …) on to the following steps (GITHUB_PATH, GITHUB_ENV), or to this session
# when run by hand.
#
# A script rather than a setup action: the repository allows only actions pinned to a full commit
# SHA, and the setup actions for Swift use other actions by tag internally.
param(
    [string]$Version = '6.4.3',
    # swift.org's installer for that version; change both together.
    [string]$Sha256 = 'a4f1369833f77de28dbac998c8debe1c1d6044410dc6380238ae61a0d7ce5f77'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$build = "swift-$Version-RELEASE"
$url = "https://download.swift.org/swift-$Version-release/windows10/$build/$build-windows10.exe"
$temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$installer = Join-Path $temp "$build-windows10.exe"

Write-Host "Downloading $url"
(New-Object System.Net.WebClient).DownloadFile($url, $installer)
$hash = (Get-FileHash -Algorithm SHA256 $installer).Hash.ToLowerInvariant()
if ($hash -ne $Sha256.ToLowerInvariant()) { throw "The installer's SHA-256 is $hash, expected $Sha256." }
$signature = Get-AuthenticodeSignature $installer
if ($signature.Status -ne 'Valid') { throw "The installer's signature is $($signature.Status)." }
# swift.org's Windows installers are signed by Apple.
if ($signature.SignerCertificate.Subject -notmatch '(^|, )O=Apple Inc\.(,|$)') {
    throw "The installer is signed by $($signature.SignerCertificate.Subject), not Apple."
}
Write-Host "Checked: SHA-256 matches; signed by $($signature.SignerCertificate.Subject)"

# The variables before, to pass on only what the installer added.
$before = @{}
foreach ($level in 'Machine', 'User') {
    [Environment]::GetEnvironmentVariables($level).GetEnumerator() | ForEach-Object { $before["$level|$($_.Name)"] = $_.Value }
}
$log = Join-Path $temp 'swift-install.log'
$process = Start-Process -FilePath $installer -ArgumentList '/quiet', '/norestart', '/log', $log -Wait -PassThru
if ($process.ExitCode -notin 0, 3010) {
    Get-Content $log -Tail 40 -ErrorAction SilentlyContinue
    throw "The Swift installer failed ($($process.ExitCode))."
}

$paths = @()
$variables = @{}
foreach ($level in 'Machine', 'User') {
    [Environment]::GetEnvironmentVariables($level).GetEnumerator() | ForEach-Object {
        if ($_.Name -eq 'Path') {
            $old = @(("$($before["$level|Path"])" -split ';') | Where-Object { $_ })
            $paths += @(($_.Value -split ';') | Where-Object { $_ -and $old -notcontains $_ })
        } elseif ($before["$level|$($_.Name)"] -ne $_.Value) {
            $variables[$_.Name] = $_.Value
        }
    }
}
$paths = $paths | Select-Object -Unique
foreach ($name in $variables.Keys) {
    Write-Host "$name=$($variables[$name])"
    if ($env:GITHUB_ENV) { "$name=$($variables[$name])" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append }
    Set-Item -Path "Env:$name" -Value $variables[$name]
}
foreach ($entry in $paths) {
    Write-Host "PATH += $entry"
    if ($env:GITHUB_PATH) { $entry | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append }
}
$env:Path = (@($paths) + @($env:Path -split ';')) -join ';'
& swift --version
if ($LASTEXITCODE -ne 0) { throw 'swift does not run after the install.' }
