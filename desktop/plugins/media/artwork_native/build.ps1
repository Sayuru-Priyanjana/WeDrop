# Rebuilds wedrop_artwork.dll from artwork.cpp using MSVC (Build Tools for
# Visual Studio, "Desktop development with C++" workload). Not part of the
# normal `wails build`/`wails dev` Go compile step — cgo on Windows expects a
# gcc-compatible compiler, and this needs the real C++/WinRT projection
# headers, which only ship for MSVC. Re-run this manually whenever
# artwork.cpp changes; the committed .dll is what desktop/plugins/media
# actually loads at runtime (see artwork_windows.go).
$ErrorActionPreference = "Stop"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw "No Visual Studio installation with the C++ build tools was found." }

$vcvarsall = Join-Path $vsPath "VC\Auxiliary\Build\vcvarsall.bat"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

cmd /c "`"$vcvarsall`" x64 && cd /d `"$scriptDir`" && cl /EHsc /std:c++20 /O2 /LD artwork.cpp /Fe:wedrop_artwork.dll /link runtimeobject.lib ole32.lib oleaut32.lib windowsapp.lib"
if ($LASTEXITCODE -ne 0) { throw "Build failed" }

Remove-Item -ErrorAction SilentlyContinue "$scriptDir\artwork.obj", "$scriptDir\wedrop_artwork.exp", "$scriptDir\wedrop_artwork.lib"
Write-Host "Built $scriptDir\wedrop_artwork.dll"
