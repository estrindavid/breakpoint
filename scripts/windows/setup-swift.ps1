# Installs the Swift toolchain on a Windows CI runner, straight from swift.org.
#
#   scripts/windows/setup-swift.ps1 -Version swift-6.4.3-release -Build 6.4.3-RELEASE
#
# The workflows run this instead of a marketplace action: the repository only allows actions pinned
# to a full commit (docs/MAINTAINING.md), and that covers the actions an action uses inside, which
# the usual Swift setup action does not pin. This does the same three things: download the
# installer, run it quietly, and hand the environment it sets (PATH, SDKROOT) to the next steps.
# For CI only: on your own PC, install Swift from swift.org or with winget (CONTRIBUTING.md).
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Build
)
$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_ENV -or -not $env:GITHUB_PATH) { throw 'setup-swift.ps1 is for GitHub Actions runners.' }

$url = "https://download.swift.org/$Version/windows10/swift-$Build/swift-$Build-windows10.exe"
$installer = Join-Path $env:RUNNER_TEMP 'swift-installer.exe'
$log = Join-Path $env:RUNNER_TEMP 'swift-install.log'

Write-Host "Downloading $url"
$attempt = 0
while ($true) {
    $attempt += 1
    try {
        Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
        break
    } catch {
        if ($attempt -ge 3) { throw "Could not download the Swift installer: $($_.Exception.Message)" }
        Start-Sleep -Seconds (10 * $attempt)
    }
}

# Run nothing that Windows does not accept as signed by its publisher.
$signature = Get-AuthenticodeSignature -FilePath $installer
if ($signature.Status -ne 'Valid') { throw "The Swift installer's signature is $($signature.Status)." }
Write-Host "Signed by: $($signature.SignerCertificate.Subject)"

$process = Start-Process -FilePath $installer -ArgumentList @('/quiet', '/norestart', '/log', $log) -Wait -PassThru
if ($process.ExitCode -notin 0, 3010) {
    if (Test-Path $log) { Get-Content $log -Tail 60 | Write-Host }
    throw "The Swift installer exited with $($process.ExitCode)."
}

# The installer sets machine and user variables; this process and the next steps have not seen them.
$paths = @($env:Path -split ';')
foreach ($level in 'Machine', 'User') {
    $variables = [Environment]::GetEnvironmentVariables($level)
    foreach ($name in $variables.Keys) {
        $value = [string]$variables[$name]
        if ($name -eq 'Path') {
            $paths += $value -split ';'
        } elseif ($value -notmatch "[`r`n]" -and $value -ne [Environment]::GetEnvironmentVariable($name)) {
            Set-Item -Path "Env:$name" -Value $value
            "$name=$value" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
        }
    }
}
$paths = @($paths | Where-Object { $_ } | Select-Object -Unique)
$env:Path = $paths -join ';'
# GITHUB_PATH puts each line in front of the ones before it: write them last-first to keep the order.
$new = @($paths | Where-Object { $_ -match 'Swift' })
[Array]::Reverse($new)
$new | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append

swift --version
if ($LASTEXITCODE -ne 0) { throw 'swift is not on PATH after installing.' }
