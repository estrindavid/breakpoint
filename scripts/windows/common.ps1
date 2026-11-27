# Shared by the scripts in scripts/windows: stop on errors, find the repository, and the one
# warning the Swift 6.4 Windows toolchain prints about its own WinSDK module (not this code).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$Repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')

# swift-6.4 Windows SDK: "reference to type 'wchar_t' broken by a context change" in
# WinSDK.swiftmodule. It comes from the SDK's own module file, never from a source file here.
$ToolchainNoise = "WinSDK\.swiftmodule|wchar_t' broken by a context change"

function Assert-NoWarnings([string]$Log, [string]$What) {
    $warnings = Select-String -Path $Log -Pattern ': warning: |^warning: ' |
        Where-Object { $_.Line -notmatch $ToolchainNoise -and $_.Line -notmatch 'has a relative path\. This is invalid' }
    if ($warnings) {
        $warnings | ForEach-Object { Write-Host $_.Line }
        Write-Host "::error::$What has warnings (listed above). The project builds with zero warnings."
        exit 1
    }
}

function Invoke-Swift([string[]]$Arguments, [string]$Log) {
    Push-Location $Repo
    try {
        # The toolchain writes progress to stderr; keep it, but do not let it stop the script.
        $ErrorActionPreference = 'Continue'
        & swift @Arguments 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $Log
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -ne 0) { throw "swift $($Arguments -join ' ') failed ($code)" }
    } finally {
        Pop-Location
    }
}
