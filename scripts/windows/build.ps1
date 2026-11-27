# Builds everything (debug) on Windows: Core, the runtime, the CLI and the tray app.
#
#   scripts/windows/build.ps1                  # debug build
#   scripts/windows/build.ps1 -CheckWarnings   # and fail on any warning (CI)
#   scripts/windows/build.ps1 -Release         # release build, Swift runtime linked in (static)
param([switch]$CheckWarnings, [switch]$Release)
. (Join-Path $PSScriptRoot 'common.ps1')

$log = Join-Path ([IO.Path]::GetTempPath()) "breakpoint-build-$PID.log"
$arguments = @('build')
if ($Release) { $arguments += @('-c', 'release', '--static-swift-stdlib') }
Invoke-Swift $arguments $log
if ($CheckWarnings) { Assert-NoWarnings $log 'The build' }
