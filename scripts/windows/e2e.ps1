# The end-to-end flows on Windows: scripts/e2e.sh (the same flows as on macOS) through Git Bash,
# which comes with Git for Windows. Needs jq on the path (winget install jqlang.jq; CI runners
# have it).
#
#   scripts/windows/e2e.ps1                   # all flows
#   scripts/windows/e2e.ps1 -Verbose          # and print the app's trace for a failing flow
#   scripts/windows/e2e.ps1 -Flows away,calls # only flows whose name contains one of the words
param([string[]]$Flows = @())
. (Join-Path $PSScriptRoot 'common.ps1')

$bash = Join-Path (Split-Path (Split-Path (Get-Command git).Source)) 'bin\bash.exe'
if (-not (Test-Path $bash)) { throw "Git Bash was not found next to git ($bash)." }
$arguments = @('scripts/e2e.sh')
if ($VerbosePreference -eq 'Continue' -or $PSBoundParameters.ContainsKey('Verbose')) { $arguments += '-v' }
$arguments += $Flows
Push-Location $Repo
try {
    & $bash @arguments
    if ($LASTEXITCODE -ne 0) { throw "e2e flows failed ($LASTEXITCODE)" }
} finally {
    Pop-Location
}
