# Prints the version in Sources/BreakpointCore/Models/Version.swift (what the build is).
. (Join-Path $PSScriptRoot 'common.ps1')
$text = Get-Content (Join-Path $Repo 'Sources\BreakpointCore\Models\Version.swift') -Raw
if ($text -notmatch 'static let current = "([^"]+)"') { throw 'No version in Version.swift' }
$Matches[1]
