# Builds and packages the Windows app for a release (run by .github/workflows/release.yml, and by
# CI on every change):
#
#   scripts/windows/package.ps1 -Version 0.4.0 -OutDir build/release
#
# Writes into OutDir:
#   Breakpoint-VERSION-windows-x64.zip   the folder Breakpoint\ (what install.ps1 puts in
#                                        %LOCALAPPDATA%\Programs\Breakpoint):
#                                          Breakpoint.exe          the tray app (release, static)
#                                          bin\breakpoint.exe      the CLI the hooks call (static)
#                                          breakpoint-app.json     identifier, version, executable
#                                          Breakpoint.ico          the icon, drawn by the app itself
#                                          *.dll                   the Visual C++ runtime, app-local
#                                          LICENSE.md, NOTICE
#   install.ps1                          the one-line installer (scripts/windows/install.ps1)
#
# Signing happens elsewhere: the release workflow signs this zip with the release key on macOS,
# with the same tool as the Mac app, and writes update-feed-windows.json there.
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$OutDir,
    [switch]$SkipBuild
)
. (Join-Path $PSScriptRoot 'common.ps1')

if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') { throw "'$Version' is not X.Y.Z" }
$inSource = & (Join-Path $PSScriptRoot 'version.ps1')
if ($inSource -ne $Version) { throw "Version.swift says $inSource, the package says $Version." }

$log = Join-Path ([IO.Path]::GetTempPath()) "breakpoint-package-$PID.log"
# Static: the Swift runtime and Foundation are linked in, so neither executable needs the
# toolchain, and the CLI copy in ~\.breakpoint\bin runs on its own. No debug info (-gnone), unused
# code dropped (/OPT:REF, /OPT:ICF).
$flags = @('-c', 'release', '--static-swift-stdlib', '-Xswiftc', '-gnone', '-Xlinker', '/OPT:REF', '-Xlinker', '/OPT:ICF')
if (-not $SkipBuild) {
    Invoke-Swift (@('build', '--product', 'BreakpointApp') + $flags) $log
    Invoke-Swift (@('build', '--product', 'breakpoint') + $flags) $log
}
Push-Location $Repo
try { $bin = (& swift build -c release --show-bin-path 2>$null | Select-Object -Last 1).Trim() } finally { Pop-Location }

$OutDir = [IO.Path]::GetFullPath((Join-Path $Repo $OutDir))
$stage = Join-Path $OutDir 'stage'
$app = Join-Path $stage 'Breakpoint'
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $app 'bin') | Out-Null

# The toolchain's own tools: llvm-objcopy strips what DWARF the static libraries carried in.
$toolchain = Split-Path (Get-Command swift).Source
$objcopy = Join-Path $toolchain 'llvm-objcopy.exe'
& $objcopy --strip-debug (Join-Path $bin 'BreakpointApp.exe') (Join-Path $app 'Breakpoint.exe')
& $objcopy --strip-debug (Join-Path $bin 'breakpoint.exe') (Join-Path $app 'bin\breakpoint.exe')
if ($LASTEXITCODE -ne 0) { throw 'llvm-objcopy failed' }

# The manifest: Windows 10/11, per-monitor DPI awareness, UTF-8 as the process code page, long paths.
$sdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\mt.exe" | Sort-Object FullName | Select-Object -Last 1
if (-not $sdk) { throw 'mt.exe (Windows SDK) was not found.' }
$manifest = Join-Path $stage 'app.manifest'
@'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0" xmlns:asmv3="urn:schemas-microsoft-com:asm.v3">
  <assemblyIdentity type="win32" name="com.breakpointapp.Breakpoint" version="1.0.0.0" processorArchitecture="amd64"/>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application><supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/></application>
  </compatibility>
  <asmv3:application>
    <asmv3:windowsSettings>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
      <activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>
      <longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>
    </asmv3:windowsSettings>
  </asmv3:application>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security><requestedPrivileges><requestedExecutionLevel level="asInvoker" uiAccess="false"/></requestedPrivileges></security>
  </trustInfo>
</assembly>
'@ | Set-Content -Encoding utf8 $manifest
foreach ($exe in @((Join-Path $app 'Breakpoint.exe'), (Join-Path $app 'bin\breakpoint.exe'))) {
    & $sdk.FullName -nologo -manifest $manifest "-outputresource:$exe;#1" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "mt.exe failed for $exe" }
}

# The Visual C++ runtime, app-local, next to both executables (the CLI copy takes them along).
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath
$crt = Get-ChildItem (Join-Path $vs 'VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT') -Directory | Sort-Object FullName | Select-Object -Last 1
if (-not $crt) { throw 'The Visual C++ redistributable files were not found.' }
foreach ($name in 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll') {
    Copy-Item (Join-Path $crt.FullName $name) $app
    Copy-Item (Join-Path $crt.FullName $name) (Join-Path $app 'bin')
}

# What updates check, the icon (drawn by the app's own code), the licence.
@"
{
  "identifier": "com.breakpointapp.Breakpoint",
  "version": "$Version",
  "executable": "Breakpoint.exe"
}
"@ | Set-Content -Encoding utf8NoBOM (Join-Path $app 'breakpoint-app.json')
& (Join-Path $app 'Breakpoint.exe') --write-icon (Join-Path $app 'Breakpoint.ico') | Out-Null
$deadline = (Get-Date).AddSeconds(20)
while (-not (Test-Path (Join-Path $app 'Breakpoint.ico')) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
if (-not (Test-Path (Join-Path $app 'Breakpoint.ico'))) { throw 'The app did not write its icon.' }
Copy-Item (Join-Path $Repo 'LICENSE.md'), (Join-Path $Repo 'NOTICE') $app

$zip = Join-Path $OutDir "Breakpoint-$Version-windows-x64.zip"
Remove-Item -Force $zip -ErrorAction SilentlyContinue
& "$env:SystemRoot\System32\tar.exe" -a -c -f $zip -C $stage Breakpoint
if ($LASTEXITCODE -ne 0) { throw 'tar failed' }
Copy-Item (Join-Path $PSScriptRoot 'install.ps1') (Join-Path $OutDir 'install.ps1')
Remove-Item -Recurse -Force $stage
Get-Item $zip, (Join-Path $OutDir 'install.ps1') | ForEach-Object { '{0}  {1:N1} MB' -f $_.Name, ($_.Length / 1MB) }
