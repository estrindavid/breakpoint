# Runs the unit tests (Swift Testing) on Windows, after building the CLI the subprocess tests run.
# Extra arguments pass through to `swift test` (e.g. -Filter Wire becomes --filter Wire).
#
#   scripts/windows/test.ps1                  # all tests
#   scripts/windows/test.ps1 -Filter Socket   # only matching tests
#   scripts/windows/test.ps1 -CheckWarnings   # and fail on any warning while building them (CI)
param([string]$Filter, [switch]$CheckWarnings)
. (Join-Path $PSScriptRoot 'common.ps1')

$log = Join-Path ([IO.Path]::GetTempPath()) "breakpoint-test-$PID.log"
# The CLI tests run the built `breakpoint.exe`, which `swift test` does not rebuild.
Invoke-Swift @('build', '--product', 'breakpoint') $log
$arguments = @('test')
if ($Filter) { $arguments += @('--filter', $Filter) }
Invoke-Swift $arguments $log
if ($CheckWarnings) { Assert-NoWarnings $log 'Building the tests' }
