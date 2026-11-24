$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$version = "0.8.1"
$releaseRoot = Join-Path $projectRoot "release"
$buildRoot = Join-Path $projectRoot "tmp\portable_build"
$packageRoot = Join-Path $buildRoot "BUS_Voltage_Correction_Portable_V$version"
$zipPath = Join-Path $releaseRoot "BUS_Voltage_Correction_Portable_V$version.zip"
$checksumPath = Join-Path $releaseRoot "BUS_Voltage_Correction_Portable_V${version}_SHA256.txt"

if (Test-Path -LiteralPath $buildRoot) {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $packageRoot "assets") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $packageRoot "docs") -Force | Out-Null
New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null

$files = @(
    @{ Source = (Join-Path $projectRoot "BUS_Voltage_Correction.ps1"); Destination = (Join-Path $packageRoot "BUS_Voltage_Correction.ps1") },
    @{ Source = (Join-Path $projectRoot "open_desktop_gui.bat"); Destination = (Join-Path $packageRoot "open_desktop_gui.bat") },
    @{ Source = (Join-Path $PSScriptRoot "BUS Voltage Correction.vbs"); Destination = (Join-Path $packageRoot "BUS Voltage Correction.vbs") },
    @{ Source = (Join-Path $PSScriptRoot "README_PORTABLE.txt"); Destination = (Join-Path $packageRoot "README_PORTABLE.txt") },
    @{ Source = (Join-Path $PSScriptRoot "README_PORTABLE.zh-TW.txt"); Destination = (Join-Path $packageRoot "README_PORTABLE.zh-TW.txt") },
    @{ Source = (Join-Path $projectRoot "README.md"); Destination = (Join-Path $packageRoot "README.md") },
    @{ Source = (Join-Path $projectRoot "README.zh-TW.md"); Destination = (Join-Path $packageRoot "README.zh-TW.md") },
    @{ Source = (Join-Path $projectRoot "assets\mes_logo_light.png"); Destination = (Join-Path $packageRoot "assets\mes_logo_light.png") },
    @{ Source = (Join-Path $projectRoot "docs\RELEASE_NOTES_V0.8.1.md"); Destination = (Join-Path $packageRoot "docs\RELEASE_NOTES_V0.8.1.md") },
    @{ Source = (Join-Path $projectRoot "docs\RELEASE_NOTES_V0.8.1.zh-TW.md"); Destination = (Join-Path $packageRoot "docs\RELEASE_NOTES_V0.8.1.zh-TW.md") }
)
foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath $file.Source -PathType Leaf)) {
        throw "Portable package source file is missing: $($file.Source)"
    }
    Copy-Item -LiteralPath $file.Source -Destination $file.Destination -Force
}

if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -LiteralPath $packageRoot -DestinationPath $zipPath -CompressionLevel Optimal

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
$checksumText = @(
    "BUS Voltage Correction Portable V$version",
    "File: $(Split-Path -Leaf $zipPath)",
    "SHA256: $hash"
)
Set-Content -LiteralPath $checksumPath -Value $checksumText -Encoding ASCII

Remove-Item -LiteralPath $buildRoot -Recurse -Force
Write-Output "Portable ZIP: $zipPath"
Write-Output "SHA256: $hash"
